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

// The HTTP round-trip the usage fetch depends on, abstracted so tests can
// drive 429 / 401 / success without a network. Production uses URLSession.
protocol UsageTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct LiveUsageTransport: UsageTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
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

    // Injected so tests can supply a scripted transport; production defaults
    // to the live URLSession round-trip.
    private let transport: UsageTransport

    init(transport: UsageTransport = LiveUsageTransport()) {
        self.transport = transport
    }

    // A cached token is trusted at most this long, regardless of its own
    // expiry, so a revoked credential can't be reused for hours. A 401/403
    // (see fetch()) drops it even sooner — the moment the server rejects it.
    private static let tokenCacheCeiling: TimeInterval = 30 * 60
    // Stop trusting the cached token slightly before its real expiry, so the
    // next read picks up Claude Code's already-refreshed replacement.
    private static let tokenExpirySlack: TimeInterval = 60
    // After a failed keychain read, don't re-prompt on every refresh tick.
    private static let failureCooldownInterval: TimeInterval = 5 * 60

    enum FetchError: LocalizedError {
        case notConnected
        case keychainStatus(OSStatus)
        case credentialsUnreadable
        case tokenExpired
        case rateLimited(retryAt: Date?)
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
            case .rateLimited:
                return "The usage endpoint is rate-limiting requests (HTTP 429); showing the last known figures until it recovers."
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

    // A keychain read raises the password dialog ONLY when it was triggered by
    // an explicit gesture this run (see allowInteractiveReadOnce); automatic
    // refreshes read with UI forbidden. The app is ad-hoc signed, so an
    // "Always Allow" grant may not persist — caching the token and cooling
    // down after failures keeps a lost grant from silently hammering the
    // keychain, and reading UI-forbidden keeps it from ambushing an idle user.
    private var cachedToken: (token: String, validUntil: Date)?
    private var failureCooldown: (error: FetchError, until: Date)?
    private var cachedAccount: DetectedAccount?
    // The usage endpoint rate-limits callers aggressively — Claude Code itself
    // caches for about an hour. A 60s cache turned a 2-minute poll into ~30
    // hits/hour, which earns HTTP 429s (worse when several devices share one
    // account). Five minutes keeps a menu-bar meter fresh enough while cutting
    // endpoint load ~5x.
    private var cachedUsage: (usage: OfficialUsage, fetchedAt: Date)?
    private let usageCacheSeconds: TimeInterval = 5 * 60
    // After an HTTP 429, don't touch the endpoint again until this passes
    // (honoring Retry-After when the server sends one, else a fixed backoff).
    // The last good usage keeps showing meanwhile, so a transient limit never
    // blanks the official number or deepens the rate limit with retries.
    private var rateLimitedUntil: Date?
    private static let rateLimitBackoff: TimeInterval = 15 * 60

    // The keychain is touched only after an explicit user action THIS RUN
    // (Connect button, "Load real limits", or actively selecting the
    // Official API source) — launching the app must never ambush with a
    // credentials prompt, even when the connect preference is persisted.
    // Not persisted: a restart always starts unarmed.
    private var sessionAuthorized = false

    // Set by an explicit user gesture (authorize()) and consumed by the next
    // token read: the single read permitted to surface the keychain dialog.
    // Automatic background refreshes always read with UI forbidden.
    private var allowInteractiveReadOnce = false

    func authorize() {
        sessionAuthorized = true
        // A deliberate gesture: allow exactly one interactive keychain read,
        // and clear any failure cooldown a prior silent read left behind so
        // the deliberate read isn't swallowed by it.
        allowInteractiveReadOnce = true
        failureCooldown = nil
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
        // Under a 429 backoff, keep serving the last good usage rather than
        // hammering the endpoint (which only deepens the limit) or blanking the
        // official number over a transient rate limit.
        if let until = rateLimitedUntil, until > Date() {
            if let cached = cachedUsage { return cached.usage }
            throw FetchError.rateLimited(retryAt: until)
        }
        let token = try cachedOrFreshAccessToken()
        return try await fetchUsage(token: token)
    }

    // The network round-trip and status handling, split from fetch() so the
    // 429 / 401 / serve-stale behavior is testable through an injected
    // transport without touching the keychain. Takes the already-resolved
    // token; fetch() has already checked the usage cache and rate-limit backoff.
    func fetchUsage(token: String) async throws -> OfficialUsage {
        guard let url = URL(string: API.usageEndpoint) else {
            throw FetchError.unrecognizedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(API.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = API.requestTimeout

        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299:
                break
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Self.retryAfterSeconds)
                let until = Date().addingTimeInterval(retryAfter ?? Self.rateLimitBackoff)
                rateLimitedUntil = until
                if let cached = cachedUsage { return cached.usage }
                throw FetchError.rateLimited(retryAt: until)
            case 401, 403:
                // The token the keychain handed us is no longer accepted —
                // most likely Claude Code rotated it in place. Drop our cached
                // copy so the next refresh re-reads the keychain (silently,
                // UI-forbidden) and picks up the fresh credential.
                cachedToken = nil
                throw FetchError.httpStatus(http.statusCode)
            default:
                throw FetchError.httpStatus(http.statusCode)
            }
        }
        let usage = try Self.parseUsage(data)
        cachedUsage = (usage, Date())
        rateLimitedUntil = nil
        return usage
    }

    // Retry-After is either delta-seconds or an HTTP date; parse both and
    // ignore anything unrecognized (the fixed backoff covers that). Clamped
    // so a bogus far-future value can't wedge the official source off for good.
    static func retryAfterSeconds(_ header: String) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let ceiling: TimeInterval = 60 * 60
        if let seconds = TimeInterval(trimmed) {
            return min(max(0, seconds), ceiling)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: trimmed) {
            return min(max(0, date.timeIntervalSinceNow), ceiling)
        }
        return nil
    }

    private func cachedOrFreshAccessToken() throws -> String {
        // The gate sits in front of EVERY keychain path (fetch and account
        // detection both come through here).
        guard sessionAuthorized else { throw FetchError.notConnected }
        // Consume the one-shot interactive grant regardless of whether a read
        // actually happens below, so it can never leak onto a later automatic
        // refresh and reopen the dialog the user never asked for.
        let interactive = allowInteractiveReadOnce
        allowInteractiveReadOnce = false
        if let cached = cachedToken, cached.validUntil > Date() {
            return cached.token
        }
        if let cooldown = failureCooldown, cooldown.until > Date() {
            throw cooldown.error
        }
        do {
            let (token, expiry) = try readAccessToken(interactive: interactive)
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

    // `interactive` gates the ONLY user-facing keychain dialog in the app: it
    // is true only for a read triggered by an explicit gesture this run.
    // Automatic refreshes pass false and read with UI forbidden, so a grant
    // that doesn't persist (ad-hoc build) degrades silently to the local
    // estimate instead of ambushing an idle user every time the token cache
    // expires. As with the launch probe, only SecKeychainSetUserInteraction-
    // Allowed reliably suppresses the dialog for this file-based login-keychain
    // item (interactionNotAllowed is a no-op there).
    private func readAccessToken(interactive: Bool) throws -> (String, Date?) {
        if !interactive {
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(true) } }
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
