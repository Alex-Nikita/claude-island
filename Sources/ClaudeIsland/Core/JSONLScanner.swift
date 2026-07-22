import Foundation

struct TokenTotals {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite5m = 0.0
    var cacheWrite1h = 0.0

    var total: Double { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

final class JSONLScanner {
    private struct Entry: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheCreationInputTokens: Double?
        let cacheReadInputTokens: Double?
        let cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
        }
    }

    private struct CacheCreation: Decodable {
        let ephemeral1h: Double?
        let ephemeral5m: Double?

        enum CodingKeys: String, CodingKey {
            case ephemeral1h = "ephemeral_1h_input_tokens"
            case ephemeral5m = "ephemeral_5m_input_tokens"
        }
    }

    private struct Record {
        let key: String?
        let date: Date
        let model: String
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
    }

    private struct CachedFile {
        let mtime: Date
        let size: Int
        let records: [Record]
    }

    // Files are parsed once and reused until their mtime/size changes, so the
    // periodic refresh only re-decodes the transcripts that actually grew.
    private var cache: [String: CachedFile] = [:]
    private let lock = NSLock()

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func collectUsage(since: Date) throws -> [String: TokenTotals] {
        // Recursive: subagent/workflow transcripts live at
        // projects/<dir>/<session>/subagents/**/*.jsonl and carry real usage.
        guard let enumerator = FileManager.default.enumerator(
            at: ClaudePaths.projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        lock.lock()
        defer { lock.unlock() }

        var liveRecords: [Record] = []
        var livePaths: Set<String> = []

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = values?.contentModificationDate else { continue }
            // Appends bump mtime, so an old mtime means no entries inside the window.
            if mtime < since { continue }
            let path = file.path
            let size = values?.fileSize ?? -1
            livePaths.insert(path)
            if let cached = cache[path], cached.mtime == mtime, cached.size == size {
                liveRecords.append(contentsOf: cached.records)
                continue
            }
            let records = parse(file)
            cache[path] = CachedFile(mtime: mtime, size: size, records: records)
            liveRecords.append(contentsOf: records)
        }

        for key in cache.keys where !livePaths.contains(key) {
            cache.removeValue(forKey: key)
        }

        var totals: [String: TokenTotals] = [:]
        var seen: Set<String> = []
        for record in liveRecords {
            guard record.date >= since else { continue }
            if let key = record.key {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            var t = totals[record.model] ?? TokenTotals()
            t.input += record.input
            t.output += record.output
            t.cacheRead += record.cacheRead
            t.cacheWrite5m += record.cacheWrite5m
            t.cacheWrite1h += record.cacheWrite1h
            totals[record.model] = t
        }
        return totals
    }

    private func parse(_ file: URL) -> [Record] {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return [] }
        let decoder = JSONDecoder()
        let usageMarker = Data("\"usage\"".utf8)
        let newline = UInt8(ascii: "\n")
        var records: [Record] = []

        for line in data.split(separator: newline) {
            guard line.range(of: usageMarker) != nil,
                  let entry = try? decoder.decode(Entry.self, from: line),
                  entry.type == "assistant",
                  let usage = entry.message?.usage,
                  let timestamp = entry.timestamp,
                  let date = isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp)
            else { continue }

            let cache5m: Double
            let cache1h: Double
            if let cache = usage.cacheCreation, cache.ephemeral1h != nil || cache.ephemeral5m != nil {
                cache1h = cache.ephemeral1h ?? 0
                cache5m = cache.ephemeral5m ?? 0
            } else {
                cache1h = 0
                cache5m = usage.cacheCreationInputTokens ?? 0
            }
            records.append(Record(
                key: entry.message?.id ?? entry.requestId,
                date: date,
                model: entry.message?.model ?? "unknown",
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite5m: cache5m,
                cacheWrite1h: cache1h
            ))
        }
        return records
    }
}
