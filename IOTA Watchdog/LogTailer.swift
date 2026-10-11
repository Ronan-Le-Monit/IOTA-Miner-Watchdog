//
//  LogTailer.swift
//  IOTA Watchdog
//
//  Follows the miner's log files and turns newly appended bytes into `LogEvent`s.
//
//  Why this is more than "read the file":
//    • cli.log rotates at 10 MB — roughly ONCE PER HOUR while training. The current file is
//      renamed to "<date>-cli.old.log" (only one .old is kept) and a new empty cli.log appears.
//      Measured on 2026-09-04: 15:53→16:51 filled 10 MB. Total history on disk is only ~1.5 h,
//      so the watchdog must follow the log live and keep its own state; it cannot look back.
//    • A new date-named file starts each day around 02:00.
//    • main.log is small (~100 KB/day) and is NOT rotated hourly, so it holds the whole day's
//      lifecycle events and is the durable source for start/exit history.
//

import Foundation

/// Follows one file by byte offset, surviving truncation and rotation.
private final class FollowedFile {
    let url: URL
    private var handle: FileHandle?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    /// Bytes read but not yet terminated by a newline.
    private var partial = Data()
    /// Reassembles multi-line Electron objects (see LogLineStream).
    private var stream = LogLineStream()
    /// When the Python worker last wrote a line to this file. Kept here rather than read from
    /// `stream`, which is replaced on rotation.
    private(set) var lastWorkerLineAt: Date?

    /// How much of an already-large file to read when we first open it. Everything older than
    /// this is history we cannot act on anyway. ~100 KB of cli.log is about one minute.
    private let bootstrapBytes: UInt64

    init(url: URL, bootstrapBytes: UInt64) {
        self.url = url
        self.bootstrapBytes = bootstrapBytes
    }

    deinit { try? handle?.close() }

    /// Reads whatever is new and returns the events found. Never throws: a log we cannot read
    /// must not take the watchdog down, it shows up as a stale `logAge` instead.
    func readNewEvents() -> [LogEvent] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return []
        }

        var events: [LogEvent] = []

        // A different inode at the same path means the file was rotated. Drain what is left of
        // the old handle first so nothing is lost, then start on the new file from byte 0.
        if handle != nil, currentInode != inode {
            events += drainCurrentHandle()
            closeHandle()
        }

        // Truncated in place (shouldn't happen, but cheap to survive): start over.
        if handle != nil, size < offset {
            offset = 0
            try? handle?.seek(toOffset: 0)
            partial.removeAll()
            stream = LogLineStream()
        }

        if handle == nil {
            guard let opened = try? FileHandle(forReadingFrom: url) else { return events }
            handle = opened
            inode = currentInode
            // Skip ancient history, then discard the first (probably partial) line.
            let start = size > bootstrapBytes ? size - bootstrapBytes : 0
            offset = start
            try? opened.seek(toOffset: start)
            partial.removeAll()
            stream = LogLineStream()
            if start > 0, let chunk = try? opened.read(upToCount: 64 * 1024) {
                if let newline = chunk.firstIndex(of: 0x0A) {
                    offset = start + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
                    try? opened.seek(toOffset: offset)
                } else {
                    offset = start + UInt64(chunk.count)
                }
            }
        }

        events += drainCurrentHandle()
        return events
    }

    /// Reads to end of file, emitting an event per complete line.
    private func drainCurrentHandle() -> [LogEvent] {
        guard let handle else { return [] }
        var events: [LogEvent] = []
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            partial.append(chunk)
            events += consumeCompleteLines()
        }
        return events
    }

    /// Splits `partial` on newlines, feeding every complete line to the stream and keeping the
    /// unterminated remainder for next time.
    private func consumeCompleteLines() -> [LogEvent] {
        var events: [LogEvent] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<newline]
            partial = partial[partial.index(after: newline)...]
            // Logs are UTF-8; fall back to lossy so one bad byte can't stall the tailer.
            let line = String(data: lineData, encoding: .utf8)
                ?? String(decoding: lineData, as: UTF8.self)
            if let event = stream.consume(line) { events.append(event) }
        }
        if let seen = stream.lastWorkerLineAt {
            lastWorkerLineAt = max(lastWorkerLineAt ?? .distantPast, seen)
        }
        // Compact so `partial` doesn't keep a growing slice's backing store alive.
        partial = Data(partial)
        return events
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        inode = 0
        offset = 0
        partial.removeAll()
        stream = LogLineStream()
    }

    /// Drops the handle so the next read re-resolves the file (used when the path changes).
    func reset() { closeHandle() }
}

/// Resolves and follows the current cli.log and main.log.
final class LogTailer {

    /// Directory holding the miner's logs. Defaults to the real location under the user's home.
    let directory: URL

    private var cli: FollowedFile?
    private var main: FollowedFile?
    private var cliURL: URL?
    private var mainURL: URL?

    /// cli.log is huge; only the tail is worth reading on first open. main.log is small enough
    /// to read in full so the day's start/exit history is available immediately.
    private let cliBootstrapBytes: UInt64 = 512 * 1024
    private let mainBootstrapBytes: UInt64 = 8 * 1024 * 1024

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/IOTA Train at Home")
    }

    /// The cli.log currently being followed, if any. Exposed for `logAge`.
    var currentCLIURL: URL? { cliURL }

    /// When the Python worker last wrote any line, recognised or not, across day changes.
    private(set) var lastWorkerLineAt: Date?

    /// Modification time of the followed cli.log — the "is the worker still writing?" signal.
    var cliModifiedAt: Date? {
        guard let cliURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: cliURL.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    /// Re-resolves the newest log files and returns every event appended since the last call,
    /// sorted by timestamp.
    func poll() -> [LogEvent] {
        var events: [LogEvent] = []

        let newestCLI = newestFile(matching: { $0.hasSuffix("-cli.log") })
        if newestCLI != cliURL {
            // Day rolled over or first run: drain the file we were on, then switch.
            if let cli {
                events += cli.readNewEvents()
                if let seen = cli.lastWorkerLineAt {
                    lastWorkerLineAt = max(lastWorkerLineAt ?? .distantPast, seen)
                }
            }
            cliURL = newestCLI
            cli = newestCLI.map { FollowedFile(url: $0, bootstrapBytes: cliBootstrapBytes) }
        }

        let newestMain = newestFile(matching: { $0.hasSuffix("-main.log") })
        if newestMain != mainURL {
            if let main { events += main.readNewEvents() }
            mainURL = newestMain
            main = newestMain.map { FollowedFile(url: $0, bootstrapBytes: mainBootstrapBytes) }
        }

        if let cli { events += cli.readNewEvents() }
        if let main { events += main.readNewEvents() }

        if let seen = cli?.lastWorkerLineAt {
            lastWorkerLineAt = max(lastWorkerLineAt ?? .distantPast, seen)
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Newest file in the directory whose name matches, by name (the names are date-prefixed and
    /// therefore sort chronologically). `-cli.old.log` is excluded by the caller's predicate.
    private func newestFile(matching predicate: (String) -> Bool) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        // "2026-09-04-cli.old.log" also ends in "-cli.log"? No — it ends in ".old.log".
        // Guard anyway so a future naming change can't make us follow the rotated copy.
        let candidates = names.filter { predicate($0) && !$0.contains(".old.") }
        guard let newest = candidates.max() else { return nil }
        return directory.appendingPathComponent(newest)
    }
}
