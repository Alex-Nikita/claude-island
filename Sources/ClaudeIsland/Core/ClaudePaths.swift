import Foundation

enum ClaudePaths {
    // Tests point this at a fixture directory so nothing ever touches the
    // real ~/.claude. Production never sets it.
    static var overrideHome: URL?

    static var home: URL { overrideHome ?? FileManager.default.homeDirectoryForCurrentUser }
    static var claudeDir: URL { home.appendingPathComponent(".claude") }
    static var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    static var sessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    static var userSettings: URL { claudeDir.appendingPathComponent("settings.json") }
    static var userSkillsDir: URL { claudeDir.appendingPathComponent("skills") }
    static var userAgentsDir: URL { claudeDir.appendingPathComponent("agents") }
}
