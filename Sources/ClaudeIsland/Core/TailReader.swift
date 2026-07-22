import Foundation

// The transcript and event readers all need the same move: read only the
// last N bytes of an append-only JSONL file and walk its lines. One reader
// keeps the seek arithmetic in one place; each call site keeps its own
// window size and line cap (they differ for documented reasons).
enum TailReader {
    /// The final `maxBytes` of the file, or nil when it can't be read. The
    /// first line of the window may be a partial record — the per-line JSON
    /// parsing at every call site skips it naturally.
    static func tail(of url: URL, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        return try? handle.readToEnd()
    }

    /// tail(of:maxBytes:) split into newline-delimited lines (slices share
    /// the tail buffer; re-wrap in Data(...) before JSONSerialization).
    static func tailLines(of url: URL, maxBytes: UInt64) -> [Data.SubSequence] {
        tail(of: url, maxBytes: maxBytes)?.split(separator: UInt8(ascii: "\n")) ?? []
    }
}
