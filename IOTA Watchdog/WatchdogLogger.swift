//
//  WatchdogLogger.swift
//  IOTA Watchdog
//
//  Appends the watchdog's own decisions to ~/Library/Logs/IOTA Watchdog/watchdog.log so there is
//  a record of every restart and why it happened. Rotates at 5 MB, keeping one previous file.
//

import Foundation

final class WatchdogLogger {

    static let shared = WatchdogLogger()

    private let directory: URL
    private let fileURL: URL
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let queue = DispatchQueue(label: "watchdog.logger")
    private let formatter: DateFormatter

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/IOTA Watchdog")
        self.fileURL = self.directory.appendingPathComponent("watchdog.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Where the log lives, for the "Open log folder" menu item.
    var logDirectory: URL { directory }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [self] in
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size >= maxBytes else { return }
        let previous = directory.appendingPathComponent("watchdog.old.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}
