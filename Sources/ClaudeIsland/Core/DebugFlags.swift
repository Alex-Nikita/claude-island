import Foundation

// Test/preview scaffolding in one place: the CI_* environment switches the
// UI test harness sets to force specific states. Read once at first use —
// the environment can't change mid-run.
enum DebugFlags {
    /// Pretend a session needs attention (lights the attention border).
    static let forceAttention = flag("CI_TEST_ATTENTION")
    /// Fire a completion pulse a few seconds after launch.
    static let simulatePulse = flag("CI_TEST_PULSE")
    /// Fake a no-caps account to preview the ∞ presentation.
    static let mockUnlimited = flag("CI_TEST_UNLIMITED")
    /// NSLog each attention session as it is applied.
    static let logAttention = flag("CI_DEBUG_ATTENTION")
    /// Open the notch pre-navigated to the Context page.
    static let openContext = flag("CI_TEST_CONTEXT")
    /// Open the notch pre-navigated to Settings.
    static let openSettings = flag("CI_TEST_SETTINGS")
    /// Start with the notch island expanded.
    static let startExpanded = flag("CI_START_EXPANDED")

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }
}
