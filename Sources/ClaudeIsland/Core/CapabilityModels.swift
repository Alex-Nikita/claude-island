import Foundation

struct SkillInfo: Identifiable, Equatable {
    let name: String
    let detail: String
    let source: String
    var path: String?

    var id: String { source + "/" + name }
}

struct HookInfo: Identifiable, Equatable {
    let event: String
    let matcher: String?
    let command: String
    let source: String
    var sourcePath: String?

    var id: String { source + "/" + event + "/" + (matcher ?? "") + "/" + command }
}

struct SubagentInfo: Identifiable, Equatable {
    let name: String
    let detail: String
    let source: String
    var path: String?

    var id: String { source + "/" + name }
}

struct SessionCapabilities: Equatable {
    var skills: [SkillInfo] = []
    var hooks: [HookInfo] = []
    var subagents: [SubagentInfo] = []
}
