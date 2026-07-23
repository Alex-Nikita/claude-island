import Foundation

// Every user-facing reading of a snapshot, derived once from the snapshot
// plus the two Display choices (unit, direction). The pill, the collapsed
// wing, the dropdown header, and the island settings overview all read from
// here, so their numbers can never drift apart.
struct UsageSummary {
    let snapshot: UsageSnapshot?
    let unit: DisplayUnit
    let direction: PercentDisplay

    /// The number shown everywhere compact (pill, notch wing, corners).
    var compactText: String {
        guard let snapshot else { return "–" }
        if snapshot.isUnconfigured { return "–" }
        switch unit {
        case .percent:
            if snapshot.isUnlimited { return "∞" }
            return "\(displayedPercent(snapshot))%"
        case .dollars:
            guard let used = snapshot.dollarsUsed else { return snapshot.isUnlimited ? "∞" : "–" }
            // Balance needs a dollar cap; without one (unlimited, or a
            // percent-only limit before the estimate lands) show spend.
            if direction == .left, let budget = snapshot.dollarsBudget {
                return Format.compactDollars(max(0, budget - used))
            }
            return Format.compactDollars(used)
        }
    }

    /// Long form for tooltips and accessibility, e.g. "37% of your Claude
    /// usage used (Weekly · Fable)" or "$22.66 of your budget left".
    var accessibilityDescription: String {
        guard let snapshot else { return "No usage data yet" }
        if snapshot.isUnconfigured {
            return "Usage unknown — connect your Claude account or choose a Custom plan to set a budget"
        }
        if snapshot.isUnlimited, unit == .percent {
            return "No usage caps on this account"
        }
        let word = direction == .left ? "left" : "used"
        switch unit {
        case .percent:
            return "\(displayedPercent(snapshot))% of your Claude usage \(word) (\(snapshot.windowLabel))"
        case .dollars:
            guard let used = snapshot.dollarsUsed else { return "No cost data yet" }
            if snapshot.isUnlimited {
                return "\(Format.compactDollars(used)) spent — no usage caps on this account"
            }
            if direction == .left, let budget = snapshot.dollarsBudget {
                return "\(Format.compactDollars(max(0, budget - used))) of your \(Format.compactDollars(budget)) budget left (\(snapshot.windowLabel))"
            }
            return "\(Format.compactDollars(used)) used (\(snapshot.windowLabel))"
        }
    }

    /// Big number + its qualifier word for the overview panes, honoring
    /// both Display choices and the unlimited state.
    var headline: (number: String, suffix: String) {
        guard let snapshot else { return ("–", "") }
        if snapshot.isUnconfigured { return ("–", "") }
        if snapshot.isUnlimited {
            if unit == .dollars, let used = snapshot.dollarsUsed {
                return (Format.compactDollars(used), "spent · unlimited")
            }
            return ("∞", "unlimited")
        }
        return (compactText, direction == .left ? "left" : "used")
    }

    /// "12.3M wtd of 300M tok" — or just the spend line when unlimited.
    var usedOfBudgetLine: String? {
        guard let snapshot, !snapshot.isUnconfigured else { return nil }
        return snapshot.isUnlimited
            ? snapshot.usedDisplay
            : "\(snapshot.usedDisplay) of \(snapshot.budgetDisplay)"
    }

    /// "Weekly (rolling) · Cached usage (tokens)" — or a setup hint when there
    /// is no connected account and no Custom plan to give the number meaning.
    var metaLine: String? {
        guard let snapshot else { return nil }
        if snapshot.isUnconfigured { return "Connect your account or pick a Custom plan" }
        return "\(snapshot.windowLabel) · \(snapshot.sourceLabel)"
    }

    /// Progress-bar fill (share of budget used); nil hides the bar.
    var usedFraction: Double? {
        guard let snapshot, !snapshot.isUnlimited, !snapshot.isUnconfigured else { return nil }
        return min(max(1 - snapshot.percentLeft / 100, 0), 1)
    }

    private func displayedPercent(_ snapshot: UsageSnapshot) -> Int {
        let left = Int(snapshot.percentLeft.rounded())
        return direction == .left ? left : 100 - left
    }
}
