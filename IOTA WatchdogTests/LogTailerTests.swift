//
//  LogTailerTests.swift
//  IOTA WatchdogTests
//
//  Rotation is the interesting part: cli.log fills 10 MB and rotates roughly once per hour
//  while training, so these paths run constantly in production.
//

import XCTest
@testable import IOTA_Watchdog

final class LogTailerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogTailerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func write(_ name: String, _ lines: [String]) throws {
        let text = lines.map { $0 + "\n" }.joined()
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func append(_ name: String, _ lines: [String]) throws {
        let url = directory.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try handle.close()
    }

    private func submit(_ time: String) -> String {
        "[2026-09-04 \(time).000] [info]  2026-09-04 \(time).000 | DEBUG    | subnet.common_api_client:orchestrator_request:34 - Making orchestrator request | method: POST | path: /miner/submit_activation"
    }

    private func shutdown(_ time: String) -> String {
        "[2026-09-04 \(time).000] [info]  2026-09-04 \(time).000 | INFO     | miner.new_miner:run_miner:1940 - 🛑 Miner shutdown complete"
    }

    // MARK: Tests

    func testReadsAppendedLinesOnly() throws {
        try write("2026-09-04-cli.log", [submit("10:00:00")])
        let tailer = LogTailer(directory: directory)

        let first = tailer.poll()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.kind, .submitActivation)

        // Nothing new -> no events.
        XCTAssertTrue(tailer.poll().isEmpty)

        try append("2026-09-04-cli.log", [submit("10:00:30"), shutdown("10:01:00")])
        let second = tailer.poll()
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.last?.kind, .shutdownComplete)
    }

    /// The rotated copy must never be followed, even though its name also contains "-cli".
    func testIgnoresRotatedOldFile() throws {
        try write("2026-09-04-cli.old.log", [submit("09:00:00")])
        try write("2026-09-04-cli.log", [submit("10:00:00")])
        let tailer = LogTailer(directory: directory)

        let events = tailer.poll()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tailer.currentCLIURL?.lastPathComponent, "2026-09-04-cli.log")
    }

    /// Real rotation: current file is renamed to .old and a fresh empty cli.log is created.
    /// Lines written to the old file just before the rename must still be delivered.
    func testRotationDrainsOldFileThenFollowsNewOne() throws {
        try write("2026-09-04-cli.log", [submit("10:00:00")])
        let tailer = LogTailer(directory: directory)
        XCTAssertEqual(tailer.poll().count, 1)

        // A line lands in the file we are holding open, then rotation happens before we poll.
        try append("2026-09-04-cli.log", [submit("10:59:59")])
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("2026-09-04-cli.log"),
            to: directory.appendingPathComponent("2026-09-04-cli.old.log"))
        try write("2026-09-04-cli.log", [shutdown("11:00:01")])

        let events = tailer.poll()
        let kinds = events.map(\.kind)
        XCTAssertEqual(kinds, [.submitActivation, .shutdownComplete],
                       "the pre-rotation line and the new file's line must both arrive, in order")
    }

    /// A new day starts a new file name; the tailer must switch to it.
    func testFollowsNewDayFile() throws {
        try write("2026-09-04-cli.log", [submit("23:59:00")])
        let tailer = LogTailer(directory: directory)
        XCTAssertEqual(tailer.poll().count, 1)

        try write("2026-09-05-cli.log",
                  ["[2026-09-05 02:00:00.000] [info]  2026-09-05 02:00:00.000 | INFO     | miner.new_miner:run_miner:1845 - 🚀 Starting miner 🚀"])
        let events = tailer.poll()
        XCTAssertEqual(events.map(\.kind), [.minerStarting])
        XCTAssertEqual(tailer.currentCLIURL?.lastPathComponent, "2026-09-05-cli.log")
    }

    /// main.log is followed alongside cli.log and its events are merged in timestamp order.
    func testMergesCLIAndMainInTimestampOrder() throws {
        try write("2026-09-04-cli.log", [shutdown("11:10:15")])
        try write("2026-09-04-main.log", [
            "[2026-09-04 11:10:16.742] [info]  [TrainingControl] miner process exited code=0 signal=null",
            "[2026-09-04 12:36:24.043] [info]  [TrainingControl] start request received",
            "[2026-09-04 12:36:24.305] [info]  [TrainingControl] miner process spawned"
        ])
        let tailer = LogTailer(directory: directory)

        let kinds = tailer.poll().map(\.kind)
        XCTAssertEqual(kinds, [.shutdownComplete,
                               .processExited(code: "0", signal: "null"),
                               .startRequested,
                               .processSpawned])
    }

    /// A line split across two polls (writer mid-line) must not be parsed twice or dropped.
    func testHandlesPartialLineAcrossPolls() throws {
        let line = submit("10:00:00")
        let cut = line.index(line.startIndex, offsetBy: 60)
        try write("2026-09-04-cli.log", [])
        try append("2026-09-04-cli.log", [])

        let url = directory.appendingPathComponent("2026-09-04-cli.log")
        try Data(String(line[..<cut]).utf8).write(to: url)

        let tailer = LogTailer(directory: directory)
        XCTAssertTrue(tailer.poll().isEmpty, "an unterminated line yields nothing yet")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(line[cut...]) + "\n").utf8))
        try handle.close()

        XCTAssertEqual(tailer.poll().map(\.kind), [.submitActivation])
    }

    /// On first open of an already-huge file we read only the tail, and must not emit a broken
    /// half-line from the seek point.
    func testBootstrapSkipsHistoryWithoutEmittingPartialLine() throws {
        var lines = (0..<8000).map { _ in submit("10:00:00") }
        lines.append(shutdown("10:30:00"))
        try write("2026-09-04-cli.log", lines)

        let size = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("2026-09-04-cli.log").path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 512 * 1024, "fixture must exceed the bootstrap window")

        let tailer = LogTailer(directory: directory)
        let events = tailer.poll()
        XCTAssertLessThan(events.count, lines.count, "history before the bootstrap window is skipped")
        XCTAssertEqual(events.last?.kind, .shutdownComplete, "the newest line is always delivered")
        XCTAssertTrue(events.allSatisfy { $0.kind == .submitActivation || $0.kind == .shutdownComplete },
                      "no garbage event from the middle of a line")
    }

    func testMissingDirectoryIsSurvivable() {
        let tailer = LogTailer(directory: directory.appendingPathComponent("nope"))
        XCTAssertTrue(tailer.poll().isEmpty)
        XCTAssertNil(tailer.cliModifiedAt)
    }

    func testCLIModifiedAtTracksTheFollowedFile() throws {
        try write("2026-09-04-cli.log", [submit("10:00:00")])
        let tailer = LogTailer(directory: directory)
        _ = tailer.poll()
        let modified = try XCTUnwrap(tailer.cliModifiedAt)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 30)
    }
}
