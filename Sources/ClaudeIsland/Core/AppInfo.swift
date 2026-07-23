import Foundation

// App identity in one place. `version` is the single source of truth: the
// Makefile greps it out of this file at bundle time and stamps it into the
// app's Info.plist, so the About page and Finder can never disagree.
enum AppInfo {
    static let name = "Claude Island"
    static let version = "1.2.2"
    static let author = "Alex Nikita"
    static let gitHubHandle = "Alex-Nikita"
    static let gitHubProfileURL = "https://github.com/Alex-Nikita"
    static let repositoryURL = "https://github.com/Alex-Nikita/claude-island"
    static let license = "Apache-2.0"
}
