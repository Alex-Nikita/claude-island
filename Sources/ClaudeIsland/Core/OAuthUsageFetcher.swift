import Foundation
import Security

// Dollar metering (enterprise/Team seats with credit limits) — the window
// endpoints carry used_dollars/limit_dollars there instead of percentages.
struct DollarUsage: Equatable {
    let used: Double
    let limit: Double?
    let resetsAt: Date?
}

struct OfficialUsage {
    let fiveHourUtilization: Double?
    let fiveHourResetsAt: Date?
    let sevenDayUtilization: Double?
    let sevenDayResetsAt: Date?
    var limits: [OfficialLimit] = []
    var fiveHourDollars: DollarUsage?
    var sevenDayDollars: DollarUsage?
    // Enterprise credit-metered seats: the monthly spend cap carried by the
    // top-level `spend`/`extra_usage` objects (these accounts report null
    // windows and an empty limits array).
    var monthlyCredits: DollarUsage?
    // True when the endpoint answered but reported no limit of any kind —
    // an account without usage caps, not a failure.
    var isUnlimited: Bool {
        limits.isEmpty && fiveHourUtilization == nil && sevenDayUtilization == nil
            && fiveHourDollars?.limit == nil && sevenDayDollars?.limit == nil
            && monthlyCredits?.limit == nil
    }
}

// An actor: the token/usage caches and failure cooldown are mutable state
// shared between the snapshot fetch and account detection — actor isolation
// makes concurrent use safe by construction instead of relying on callers
// staying serialized. It also keeps keychain reads (which can block on a
// user-facing prompt) off the main actor.
actor OAuthUsageFetcher {
    private enum API {
        static let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
        static let oauthBetaHeader = "oauth-2025-04-20"
        // The usage endpoint rate-limits unknown callers aggressively;
        // identify as a claude-code client plus our own name.
        static let userAgent = "claude-code/2.1 (Claude Island)"
        static let keychainService = "Claude Code-credentials"
        static let requestTimeout: TimeInterval = 15
    }

    // A cached token is trusted at most this long, regardless of its own
    // expiry, so a revoked credential can't be reused for hours.
    private static let tokenCacheCeiling: TimeInterval = 30 * 60
    // Refresh slightly before the credential's real expiry.
    private static let tokenExpirySlack: TimeInterval = 60
    // After a failed keychain read, don't re-prompt on every refresh tick.
    private static let failureCooldownInterval: TimeInterval = 5 * 60

    enum FetchError: LocalizedError {
        case notConnected
        case keychainStatus(OSStatus)
        case credentialsUnreadable
        case tokenExpired
        case httpStatus(Int)
        case unrecognizedResponse

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "The Claude account isn't connected this launch — real limits load only after you press Connect."
            case .keychainStatus(let status):
                return "Could not read Claude Code credentials from the keychain (status \(status))."
            case .credentialsUnreadable:
                return "Claude Code keychain credentials were not in the expected JSON shape."
            case .tokenExpired:
                return "The Claude Code OAuth token is expired."
            case .httpStatus(let code):
                return "The usage endpoint returned HTTP \(code)."
            case .unrecognizedResponse:
                return "The usage response contained no recognizable utilization data."
            }
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // Every SecItemCopyMatching can raise a user-facing keychain prompt (the
    // app is ad-hoc signed, so approvals don't persist across rebuilds).
    // Cache the token and cool down after failures so a denied or expired
    // credential doesn't re-prompt on every refresh tick.
    private var cachedToken: (token: String, validUntil: Date)?
    private var failureCooldown: (error: FetchError, until: Date)?
    private var cachedAccount: DetectedAccount?
    // The usage endpoint rate-limits non-Claude-Code callers aggressively;
    // Claude Code itself caches for an hour. Don't hit it on every 20s poll.
    private var cachedUsage: (usage: OfficialUsage, fetchedAt: Date)?
    private let usageCacheSeconds: TimeInterval = 60

    // The keychain is touched only after an explicit user action THIS RUN
    // (Connect button, "Load real limits", or actively selecting the
    // Official API source) — launching the app must never ambush with a
    // credentials prompt, even when the connect preference is persisted.
    // Not persisted: a restart always starts unarmed.
    private var sessionAuthorized = false

    func authorize() {
        sessionAuthorized = true
    }

    /// Arms the session ONLY if the credential is readable right now with
    /// zero user interaction: succeeds silently when a previous "Always
    /// Allow" still covers this build's signature, fails (without any
    /// dialog) otherwise. The read is also PRIMED into the token cache so
    /// the fetch path never touches the keychain a second time — the old
    /// probe-then-fetch double read produced a double password prompt.
    func authorizeIfAlreadyTrusted() -> Bool {
        guard !sessionAuthorized else { return true }
        // Claude Code's credential lives in the FILE-BASED login keychain
        // (what Apple calls the "legacy" keychain — an Apple API
        // distinction, unrelated to this app's history). For such items
        // LAContext.interactionNotAllowed is a no-op — verified live: it
        // still raised the ACL password dialog. The interaction switch
        // below is the only reliable no-UI guarantee for them; Apple marks
        // it deprecated, hence the build warning, accepted deliberately.
        // Interaction is restored before returning, and actor isolation
        // keeps the process-global flag from racing other keychain work.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: API.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let (token, expiry) = try? parseCredential(data)
        else { return false }
        cacheToken(token, expiry: expiry)
        sessionAuthorized = true
        return true
    }

    // Plan detection is free once the credential is read: the keychain JSON
    // carries subscriptionType and rateLimitTier (e.g. "default_claude_max_20x").
    func detectAccount() -> DetectedAccount? {
        _ = try? cachedOrFreshAccessToken()
        return cachedAccount
    }

    private static func planPreset(subscriptionType: String, rateLimitTier: String?) -> PlanPreset {
        let tier = (rateLimitTier ?? "").lowercased()
        if tier.contains("max_20x") { return .max20x }
        if tier.contains("max_5x") { return .max5x }
        if tier.contains("pro") || subscriptionType.lowercased() == "pro" { return .pro }
        if subscriptionType.lowercased() == "max" { return .max5x }
        return .custom
    }

    func fetch() async throws -> OfficialUsage {
        if let cached = cachedUsage, Date().timeIntervalSince(cached.fetchedAt) < usageCacheSeconds {
            return cached.usage
        }
        let token = try cachedOrFreshAccessToken()
        guard let url = URL(string: API.usageEndpoint) else {
            throw FetchError.unrecognizedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(API.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = API.requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
        let usage = try Self.parseUsage(data)
        cachedUsage = (usage, Date())
        return usage
    }

    private func cachedOrFreshAccessToken() throws -> String {
        // The gate sits in front of EVERY keychain path (fetch and account
        // detection both come through here).
        guard sessionAuthorized else { throw FetchError.notConnected }
        if let cached = cachedToken, cached.validUntil > Date() {
            return cached.token
        }
        if let cooldown = failureCooldown, cooldown.until > Date() {
            throw cooldown.error
        }
        do {
            let (token, expiry) = try readAccessToken()
            cacheToken(token, expiry: expiry)
            failureCooldown = nil
            return token
        } catch let error as FetchError {
            cachedToken = nil
            failureCooldown = (error, Date().addingTimeInterval(Self.failureCooldownInterval))
            throw error
        }
    }

    private func cacheToken(_ token: String, expiry: Date?) {
        let validUntil = min(
            expiry?.addingTimeInterval(-Self.tokenExpirySlack) ?? .distantFuture,
            Date().addingTimeInterval(Self.tokenCacheCeiling)
        )
        cachedToken = (token, validUntil)
    }

    private func readAccessToken() throws -> (String, Date?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: API.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw FetchError.keychainStatus(status) }
        guard let data = result as? Data else { throw FetchError.credentialsUnreadable }
        return try parseCredential(data)
    }

    // Parses the keychain JSON; caches the account facts it carries along
    // the way. Shared by the fetch path and the silent launch probe.
    private func parseCredential(_ data: Data) throws -> (String, Date?) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw FetchError.credentialsUnreadable }

        if let subscription = oauth["subscriptionType"] as? String {
            let tier = oauth["rateLimitTier"] as? String
            cachedAccount = DetectedAccount(
                subscriptionType: subscription,
                rateLimitTier: tier,
                planPreset: Self.planPreset(subscriptionType: subscription, rateLimitTier: tier)
            )
        }

        var expiry: Date?
        if let expiresAt = Self.number(oauth["expiresAt"]), expiresAt > 0 {
            expiry = Date(timeIntervalSince1970: expiresAt / 1000)
            if expiry! <= Date() {
                throw FetchError.tokenExpired
            }
        }
        return (token, expiry)
    }

    static func parseUsage(_ data: Data) throws -> OfficialUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError.unrecognizedResponse
        }
        let five = window(in: root, candidates: ["five_hour", "fiveHour", "5h", "five_hour_usage"])
        let seven = window(in: root, candidates: ["seven_day", "sevenDay", "7d", "seven_day_usage"])
        var limits = parseLimits(root["limits"])
        let fiveDollars = dollarUsage(in: root, key: "five_hour")
        let sevenDollars = dollarUsage(in: root, key: "seven_day")
        let credits = monthlyCredits(in: root)
        if let credits {
            // Surface the credit cap as a first-class limit so detected mode
            // headlines it exactly like session/weekly windows do.
            limits.append(OfficialLimit(
                kind: "monthly_credits",
                label: "Monthly credits",
                percentUsed: min(max(credits.percent, 0), 100),
                severity: credits.severity,
                resetsAt: nil,
                isActive: false
            ))
        }
        // A response is unrecognizable only if it carries NOTHING — no
        // percentages, no dollar metering, no limits array, and none of the
        // window or credit objects at all. An account without caps
        // legitimately returns nulls everywhere, and a credit account with
        // metering disabled looks similar; both parse as "unlimited", not
        // as an error.
        let sawWindowObjects = root["five_hour"] is [String: Any] || root["seven_day"] is [String: Any]
        let sawCreditObjects = root["spend"] is [String: Any] || root["extra_usage"] is [String: Any]
        guard five.utilization != nil || seven.utilization != nil || !limits.isEmpty
            || fiveDollars != nil || sevenDollars != nil || sawWindowObjects || sawCreditObjects
        else {
            throw FetchError.unrecognizedResponse
        }
        return OfficialUsage(
            fiveHourUtilization: five.utilization,
            fiveHourResetsAt: five.resetsAt,
            sevenDayUtilization: seven.utilization,
            sevenDayResetsAt: seven.resetsAt,
            limits: limits,
            fiveHourDollars: fiveDollars,
            sevenDayDollars: sevenDollars,
            monthlyCredits: credits?.dollars
        )
    }

    // Enterprise credit-metered seats (e.g. rateLimitTier
    // "default_claude_zero") report null windows and an empty limits array;
    // the real usage lives in top-level `spend` (minor currency units with an
    // exponent), mirrored by `extra_usage` (credits scaled by
    // decimal_places). Metering that is disabled (enabled false or a
    // disabled_reason set) parses as absent, not as an error — the account
    // still recognizes, it just has no active cap.
    private static func monthlyCredits(in root: [String: Any])
        -> (dollars: DollarUsage, percent: Double, severity: String)? {
        func active(_ object: [String: Any], enabledKey: String) -> Bool {
            if (object[enabledKey] as? Bool) == false { return false }
            let reason = object["disabled_reason"]
            return reason == nil || reason is NSNull
        }
        func minorAmount(_ value: Any?) -> Double? {
            guard let object = value as? [String: Any],
                  let minor = number(object["amount_minor"]) else { return nil }
            return minor / pow(10, number(object["exponent"]) ?? 2)
        }
        if let spend = root["spend"] as? [String: Any], active(spend, enabledKey: "enabled"),
           let used = minorAmount(spend["used"]) {
            let limit = minorAmount(spend["limit"])
            let percent = number(spend["percent"])
                ?? limit.flatMap { $0 > 0 ? used / $0 * 100 : nil } ?? 0
            return (DollarUsage(used: used, limit: limit, resetsAt: nil),
                    percent, (spend["severity"] as? String) ?? "normal")
        }
        if let extra = root["extra_usage"] as? [String: Any],
           active(extra, enabledKey: "is_enabled"),
           let rawUsed = number(extra["used_credits"]) {
            let scale = pow(10, number(extra["decimal_places"]) ?? 2)
            let used = rawUsed / scale
            let limit = number(extra["monthly_limit"]).map { $0 / scale }
            let percent = number(extra["utilization"])
                ?? limit.flatMap { $0 > 0 ? used / $0 * 100 : nil } ?? 0
            return (DollarUsage(used: used, limit: limit, resetsAt: nil), percent, "normal")
        }
        return nil
    }

    private static func dollarUsage(in root: [String: Any], key: String) -> DollarUsage? {
        guard let object = root[key] as? [String: Any] else { return nil }
        let used = number(object["used_dollars"])
        let limit = number(object["limit_dollars"])
        guard used != nil || limit != nil else { return nil }
        return DollarUsage(
            used: used ?? 0,
            limit: limit,
            resetsAt: date(object["resets_at"] ?? object["resetsAt"])
        )
    }

    // The limits array is the richest part of the response: every real limit
    // on the account, including per-model scoped windows, with is_active
    // marking the one currently binding.
    private static func parseLimits(_ value: Any?) -> [OfficialLimit] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let kind = entry["kind"] as? String,
                  let percent = number(entry["percent"])
            else { return nil }
            var label: String
            switch kind {
            case "session": label = "Session"
            case "weekly_all": label = "Weekly (all models)"
            default:
                label = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            if let scope = entry["scope"] as? [String: Any],
               let model = scope["model"] as? [String: Any],
               let display = model["display_name"] as? String {
                label = "Weekly · \(display)"
            }
            return OfficialLimit(
                kind: kind,
                label: label,
                percentUsed: min(max(percent, 0), 100),
                severity: (entry["severity"] as? String) ?? "normal",
                resetsAt: date(entry["resets_at"]),
                isActive: (entry["is_active"] as? Bool) ?? false
            )
        }
    }

    private static func window(
        in root: [String: Any],
        candidates: [String]
    ) -> (utilization: Double?, resetsAt: Date?) {
        var containers: [[String: Any]] = [root]
        if let nested = root["usage"] as? [String: Any] {
            containers.append(nested)
        }
        for container in containers {
            for key in candidates {
                guard let object = container[key] as? [String: Any] else { continue }
                let utilization = number(object["utilization"])
                let resetsAt = date(object["resets_at"] ?? object["resetsAt"])
                if utilization != nil || resetsAt != nil {
                    return (utilization, resetsAt)
                }
            }
        }
        return (nil, nil)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = number(value), n > 0 {
            // Heuristic: values past ~2001-09 in ms epoch are milliseconds.
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        return nil
    }
}
