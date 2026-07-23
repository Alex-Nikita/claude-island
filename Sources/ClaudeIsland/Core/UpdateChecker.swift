import Foundation

// A released version parsed from a GitHub tag ("v1.2.0" → 1.2.0). Only the
// numeric major.minor.patch is compared; a build/pre-release suffix
// (-beta.1, +sha) is ignored so it never blocks a real upgrade signal.
struct SemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

// The single published GitHub release we care about, flattened from the API.
struct ReleaseInfo: Equatable {
    let version: String        // display form, no leading "v" (e.g. "1.2.0")
    let tag: String            // raw tag ("v1.2.0")
    let name: String           // release title
    let notes: String          // release body = the changelog (markdown)
    let url: String            // html_url of the release page
    let publishedAt: Date?
}

enum UpdateStatus: Equatable {
    case unknown                       // never checked, offline, no releases yet
    case upToDate(current: String)
    case available(ReleaseInfo)

    var release: ReleaseInfo? {
        if case .available(let info) = self { return info }
        return nil
    }
}

// Checks the repo's latest GitHub release and compares it to the running
// build. Unauthenticated (60 req/hr/IP is ample for a once-per-launch check),
// sends nothing about the user, and fails soft: any error, 404 (no releases
// cut yet), or unparseable body degrades to `.unknown` and shows nothing.
actor UpdateChecker {
    private let owner = "Alex-Nikita"
    private let repo = "claude-island"
    private static let requestTimeout: TimeInterval = 12
    // Definitive answers are cached this long so repeated launches/among-tabs
    // checks don't re-hit GitHub; `.unknown` is never cached (stay retry-able).
    private let cacheSeconds: TimeInterval = 6 * 60 * 60
    private var cached: (status: UpdateStatus, at: Date)?

    private var latestReleaseURL: URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
    }

    func check(currentVersion: String) async -> UpdateStatus {
        if let cached, Date().timeIntervalSince(cached.at) < cacheSeconds {
            return cached.status
        }
        let status = await fetchStatus(currentVersion: currentVersion)
        if case .unknown = status {} else { cached = (status, Date()) }
        return status
    }

    private func fetchStatus(currentVersion: String) async -> UpdateStatus {
        guard let url = latestReleaseURL else { return .unknown }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("\(AppInfo.name)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.requestTimeout

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = Self.parseRelease(data)
        else { return .unknown }
        return Self.status(currentVersion: currentVersion, release: release)
    }

    // The pure version compare, split out so it can be tested without the
    // network: a strictly-newer release is an update; same-or-older is up to
    // date; an unparseable version on either side declines to nag (.unknown).
    static func status(currentVersion: String, release: ReleaseInfo) -> UpdateStatus {
        guard let current = SemVer(currentVersion), let latest = SemVer(release.tag) else {
            return .unknown
        }
        return latest > current ? .available(release) : .upToDate(current: currentVersion)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    // Internal so tests can exercise the parse without the network.
    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty,
              (object["draft"] as? Bool) != true,
              (object["prerelease"] as? Bool) != true
        else { return nil }
        let version = tag.first == "v" ? String(tag.dropFirst()) : tag
        return ReleaseInfo(
            version: version,
            tag: tag,
            name: (object["name"] as? String)?.isEmpty == false ? (object["name"] as! String) : tag,
            notes: (object["body"] as? String) ?? "",
            url: (object["html_url"] as? String) ?? "https://github.com/Alex-Nikita/claude-island/releases",
            publishedAt: (object["published_at"] as? String).flatMap { isoFormatter.date(from: $0) }
        )
    }
}
