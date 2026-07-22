import Foundation

// Pure FileManager/String work with no shared mutable state — safe off the main thread.
final class CapabilityScanner {
    // Generous: list rows clamp with lineLimit anyway, and the detail pane
    // wants the whole description.
    private let detailLimit = 1200

    func scan(cwd: String) -> SessionCapabilities {
        let cwdURL = URL(fileURLWithPath: cwd)
        let projectClaude = cwdURL.appendingPathComponent(".claude")

        var caps = SessionCapabilities()

        // Monorepos scatter .claude dirs: the repo root above the session's
        // cwd, and nested package dirs below it. Scan them all, labeled by
        // where they live.
        let roots = capabilityRoots(cwd: cwdURL)

        var skills: [SkillInfo] = []
        var subagents: [SubagentInfo] = []
        for root in roots {
            skills += scanSkills(dir: root.dir.appendingPathComponent("skills"), source: root.label)
            subagents += scanSubagents(dir: root.dir.appendingPathComponent("agents"), source: root.label)
        }
        skills += scanSkills(dir: ClaudePaths.userSkillsDir, source: "user")
        subagents += scanSubagents(dir: ClaudePaths.userAgentsDir, source: "user")
        caps.skills = skills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        caps.subagents = subagents.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var hooks: [HookInfo] = []
        hooks += scanHooks(settingsFile: ClaudePaths.userSettings, source: "user")
        hooks += scanHooks(settingsFile: projectClaude.appendingPathComponent("settings.json"), source: "project")
        hooks += scanHooks(settingsFile: projectClaude.appendingPathComponent("settings.local.json"), source: "local")
        caps.hooks = hooks.sorted {
            if $0.event != $1.event { return $0.event < $1.event }
            let m0 = $0.matcher ?? "", m1 = $1.matcher ?? ""
            if m0 != m1 { return m0 < m1 }
            return $0.command < $1.command
        }

        return caps
    }

    private struct CapabilityRoot {
        let dir: URL
        let label: String
    }

    // Every .claude dir relevant to this session: the cwd's own ("project"),
    // ancestors up to and including the git root (sessions opened in a
    // monorepo subfolder), and nested package dirs up to 3 levels deep.
    private func capabilityRoots(cwd: URL) -> [CapabilityRoot] {
        let fm = FileManager.default
        var roots = [CapabilityRoot(dir: cwd.appendingPathComponent(".claude"), label: "project")]

        var dir = cwd
        let homePath = ClaudePaths.home.standardizedFileURL.path
        for _ in 0..<8 {
            let parent = dir.deletingLastPathComponent()
            // Compare standardized PATHS: URL equality trips on trailing
            // slashes (homeDirectoryForCurrentUser carries one) and the walk
            // would silently escape past the home directory.
            let parentPath = parent.standardizedFileURL.path
            guard parentPath != dir.standardizedFileURL.path,
                  parentPath != homePath,
                  parentPath != "/" else { break }
            dir = parent
            let claude = dir.appendingPathComponent(".claude")
            if fm.fileExists(atPath: claude.path) {
                roots.append(CapabilityRoot(dir: claude, label: dir.lastPathComponent + " ↑"))
            }
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { break }
        }

        // Bounded breadth-first sweep below the cwd; heavy build/dependency
        // dirs are skipped and the visit count capped for pathological repos.
        let skip: Set<String> = [
            "node_modules", ".git", ".build", "build", "dist", "out", "vendor",
            "Pods", ".venv", "venv", "target", "DerivedData", ".next", ".claude",
        ]
        var queue: [(url: URL, depth: Int, rel: String)] = [(cwd, 0, "")]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (current, depth, rel) = queue.removeFirst()
            visited += 1
            // Parents at depth 0..2 register children at depth 1..3 — the
            // documented three-level bound.
            guard depth < 3,
                  let children = try? fm.contentsOfDirectory(
                      at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                  )
            else { continue }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      !skip.contains(child.lastPathComponent)
                else { continue }
                let childRel = rel.isEmpty ? child.lastPathComponent : rel + "/" + child.lastPathComponent
                let claude = child.appendingPathComponent(".claude")
                if fm.fileExists(atPath: claude.path) {
                    roots.append(CapabilityRoot(dir: claude, label: childRel))
                }
                queue.append((child, depth + 1, childRel))
            }
        }
        return roots
    }

    // MARK: - Skills

    private func scanSkills(dir: URL, source: String) -> [SkillInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SkillInfo] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            let front = parseFrontmatter(text)
            result.append(SkillInfo(
                name: front["name"] ?? entry.lastPathComponent,
                detail: truncate(front["description"] ?? ""),
                source: source,
                path: skillFile.path
            ))
        }
        return result
    }

    // MARK: - Hooks

    private func scanHooks(settingsFile: URL, source: String) -> [HookInfo] {
        guard
            let data = try? Data(contentsOf: settingsFile),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let hooksObj = obj["hooks"] as? [String: Any]
        else { return [] }

        var result: [HookInfo] = []
        for (event, value) in hooksObj {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let matcher = group["matcher"] as? String
                guard let inner = group["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    guard let command = hook["command"] as? String else { continue }
                    result.append(HookInfo(
                        event: event,
                        matcher: matcher,
                        command: command,
                        source: source,
                        sourcePath: settingsFile.path
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Subagents

    private func scanSubagents(dir: URL, source: String) -> [SubagentInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SubagentInfo] = []
        for entry in entries where entry.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            let front = parseFrontmatter(text)
            result.append(SubagentInfo(
                name: front["name"] ?? entry.deletingPathExtension().lastPathComponent,
                detail: truncate(front["description"] ?? ""),
                source: source,
                path: entry.path
            ))
        }
        return result
    }

    // MARK: - Frontmatter

    // Naive YAML: only single-line "key: value" pairs between the first pair of --- lines.
    private func parseFrontmatter(_ text: String) -> [String: String] {
        var lines = text.components(separatedBy: .newlines)[...]
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = lines.dropFirst()
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines = lines.dropFirst()

        var result: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    private func truncate(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > detailLimit else { return clean }
        return String(clean.prefix(detailLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
