import Foundation

extension TokenTotals {
    // Cache tokens weighted by their price ratio to plain input tokens,
    // approximating how Anthropic's limits actually meter usage. The ratios
    // live in Pricing so the token and dollar views can never disagree.
    var priceWeighted: Double {
        input + output
            + cacheWrite5m * Pricing.cacheWrite5mWeight
            + cacheWrite1h * Pricing.cacheWrite1hWeight
            + cacheRead * Pricing.cacheReadWeight
    }
}

final class UsageEngine {
    private let scanner = JSONLScanner()
    private let fetcher = OAuthUsageFetcher()

    func computeSnapshot(query: UsageQuery) async -> UsageSnapshot {
        switch query.source {
        case .officialAPI:
            // The fallback keeps working, but the reason travels with the
            // snapshot so Settings can say WHY the official source is out.
            var fetchError: String?
            do {
                let usage = try await fetcher.fetch()
                if let snapshot = officialSnapshot(usage: usage, query: query) {
                    return snapshot
                }
            } catch {
                fetchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            return localSnapshot(query: query,
                                 sourcePrefix: "Official API unavailable — ",
                                 fetchError: fetchError)
        case .tokenCounts, .costEstimate:
            return localSnapshot(query: query, sourcePrefix: "")
        }
    }

    func detectAccount() async -> DetectedAccount? {
        await fetcher.detectAccount()
    }

    /// Arms the fetcher's per-launch keychain gate (an explicit user action).
    func authorizeAccountAccess() async {
        await fetcher.authorize()
    }

    /// Prompt-free launch probe: arms only when access already needs no UI.
    func authorizeAccountAccessIfAlreadyTrusted() async -> Bool {
        await fetcher.authorizeIfAlreadyTrusted()
    }

    // Internal (not private) so scratch fixture harnesses can exercise the
    // response-shape ladder without network access.
    func officialSnapshot(usage: OfficialUsage, query: UsageQuery) -> UsageSnapshot? {
        // Detected mode headlines the BINDING limit — the account's tightest
        // constraint across all real windows (session, weekly, per-model) —
        // rather than a user-picked window that may be far from the cap.
        let estimate = dollarEstimate(query: query)
        // The user may pin a specific limit; otherwise headline the tightest.
        // A vanished pinned limit (e.g. a model-scoped row the account no
        // longer reports) falls back to tightest rather than failing.
        let chosen = query.preferredLimitID.flatMap { id in usage.limits.first { $0.id == id } }
        if query.mode == .detected, let binding = chosen ?? Self.bindingLimit(usage.limits) {
            return UsageSnapshot(
                percentLeft: min(max(100 - binding.percentUsed, 0), 100),
                usedDisplay: "\(Int(binding.percentUsed.rounded()))% used",
                budgetDisplay: "official limit",
                windowLabel: binding.label,
                sourceLabel: chosen != nil
                    ? "Official limit · pinned"
                    : "Official limit · tightest of \(usage.limits.count)",
                resetsAt: binding.resetsAt,
                updatedAt: Date(),
                officialLimits: usage.limits,
                dollarsUsed: estimate?.used,
                dollarsBudget: estimate?.budget
            )
        }
        let utilization: Double?
        let resetsAt: Date?
        let dollars: DollarUsage?
        switch query.window {
        case .fiveHour:
            utilization = usage.fiveHourUtilization
            resetsAt = usage.fiveHourResetsAt
            dollars = usage.fiveHourDollars
        case .weekly, .monthly:
            // The endpoint has no monthly window; weekly is the closest
            // official data (monthly queries normally use local estimates).
            utilization = usage.sevenDayUtilization
            resetsAt = usage.sevenDayResetsAt
            dollars = usage.sevenDayDollars
        }
        if let utilization, utilization.isFinite {
            return UsageSnapshot(
                percentLeft: min(max(100 - utilization, 0), 100),
                usedDisplay: "\(Int(min(max(utilization, 0), 100).rounded()))% used",
                budgetDisplay: "official limit",
                windowLabel: query.window.title,
                sourceLabel: UsageSource.officialAPI.title,
                resetsAt: resetsAt,
                updatedAt: Date(),
                officialLimits: usage.limits,
                dollarsUsed: estimate?.used,
                dollarsBudget: estimate?.budget
            )
        }
        // Credit-limited accounts (enterprise/Team seats) meter in dollars.
        // If only the other window carries the credit cap, show that one
        // rather than pretending the endpoint failed.
        let crossWindow: (DollarUsage?, String) = query.window == .fiveHour
            ? (usage.sevenDayDollars, UsageWindow.weekly.title)
            : (usage.fiveHourDollars, UsageWindow.fiveHour.title)
        let pickedDollars = (dollars?.limit != nil ? dollars : nil) ?? (crossWindow.0?.limit != nil ? crossWindow.0 : nil)
        if let pickedDollars, let limit = pickedDollars.limit, limit > 0 {
            let label = pickedDollars == dollars ? query.window.title : crossWindow.1
            return UsageSnapshot(
                percentLeft: min(max(100 * (1 - pickedDollars.used / limit), 0), 100),
                usedDisplay: Format.dollars(pickedDollars.used),
                budgetDisplay: Format.dollars(limit) + " credits",
                windowLabel: label,
                sourceLabel: "Official API · credit limit",
                resetsAt: pickedDollars.resetsAt ?? resetsAt,
                updatedAt: Date(),
                officialLimits: usage.limits,
                dollarsUsed: pickedDollars.used,
                dollarsBudget: limit
            )
        }
        // The endpoint answered and reported no cap of any kind: that's an
        // unlimited account, not a failure — never fall back to estimates
        // labeled "unavailable".
        if usage.isUnlimited {
            let spentDisplay = (usage.sevenDayDollars ?? usage.fiveHourDollars)
                .map { Format.dollars($0.used) + " spent" } ?? "no usage caps"
            return UsageSnapshot(
                percentLeft: 100,
                usedDisplay: spentDisplay,
                budgetDisplay: "unlimited",
                windowLabel: "No limits",
                sourceLabel: "Official API · no usage caps on this account",
                resetsAt: nil,
                updatedAt: Date(),
                officialLimits: [],
                isUnlimited: true,
                dollarsUsed: (usage.sevenDayDollars ?? usage.fiveHourDollars)?.used ?? estimate?.used,
                dollarsBudget: nil
            )
        }
        return nil
    }

    private static func bindingLimit(_ limits: [OfficialLimit]) -> OfficialLimit? {
        let flagged = limits.filter(\.isActive)
        return (flagged.isEmpty ? limits : flagged).max { $0.percentUsed < $1.percentUsed }
    }

    // Local money view for official-API paths: the same JSONL cost scan the
    // cost-estimate source runs. Only when the display wants dollars — it's
    // a full scan per refresh.
    private func dollarEstimate(query: UsageQuery) -> (used: Double, budget: Double)? {
        guard query.wantDollarStats else { return nil }
        guard let totals = try? scanner.collectUsage(since: windowStart(for: query.window)) else { return nil }
        let used = totals.reduce(0.0) { $0 + Pricing.cost(model: $1.key, totals: $1.value) } * query.costMultiplier
        return (used, query.costBudget)
    }

    private func localSnapshot(query: UsageQuery, sourcePrefix: String,
                               fetchError: String? = nil) -> UsageSnapshot {
        // The official source falls back to token counts, never to cost estimate.
        let effectiveSource: UsageSource = query.source == .costEstimate ? .costEstimate : .tokenCounts
        let windowLabel = query.window == .monthly
            ? "Calendar month"
            : query.window.title + " (rolling)"
        let sourceLabel = sourcePrefix + effectiveSource.title
        let budgetDisplay = effectiveSource == .costEstimate
            ? Format.dollars(query.costBudget)
            : Format.tokens(query.tokenBudget) + " tok"

        let totalsByModel: [String: TokenTotals]
        do {
            totalsByModel = try scanner.collectUsage(since: windowStart(for: query.window))
        } catch {
            return UsageSnapshot(
                percentLeft: 100,
                usedDisplay: "no data",
                budgetDisplay: budgetDisplay,
                windowLabel: windowLabel,
                sourceLabel: sourceLabel,
                resetsAt: nil,
                updatedAt: Date(),
                fetchErrorDescription: fetchError
            )
        }

        // The money view rides along regardless of source — the scan already
        // happened, the cost reduce is nearly free.
        let estimatedCost = totalsByModel.reduce(0.0) { $0 + Pricing.cost(model: $1.key, totals: $1.value) }
            * query.costMultiplier

        let used: Double
        let usedDisplay: String
        let budget: Double
        switch effectiveSource {
        case .costEstimate:
            used = estimatedCost
            usedDisplay = Format.dollars(used)
            budget = query.costBudget
        default:
            used = totalsByModel.values.reduce(0.0) {
                $0 + (query.weightCacheTokens ? $1.priceWeighted : $1.total)
            }
            usedDisplay = Format.tokens(used) + (query.weightCacheTokens ? " wtd" : "")
            budget = query.tokenBudget
        }

        return UsageSnapshot(
            percentLeft: percentLeft(used: used, budget: budget),
            usedDisplay: usedDisplay,
            budgetDisplay: budgetDisplay,
            windowLabel: windowLabel,
            sourceLabel: sourceLabel,
            resetsAt: query.window == .monthly ? nextMonthStart() : nil,
            updatedAt: Date(),
            dollarsUsed: estimatedCost,
            dollarsBudget: query.costBudget,
            fetchErrorDescription: fetchError
        )
    }

    private func windowStart(for window: UsageWindow) -> Date {
        switch window {
        case .fiveHour: return Date().addingTimeInterval(-5 * 3600)
        case .weekly: return Date().addingTimeInterval(-7 * 86400)
        case .monthly:
            // Money resets on calendar months (Anthropic bills and caps
            // spend per calendar month), not a rolling 30 days.
            let calendar = Calendar.current
            return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date().addingTimeInterval(-30 * 86400)
        }
    }

    private func nextMonthStart() -> Date? {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    private func percentLeft(used: Double, budget: Double) -> Double {
        guard budget > 0, used.isFinite else { return used > 0 ? 0 : 100 }
        return min(max(100 * (1 - used / budget), 0), 100)
    }
}
