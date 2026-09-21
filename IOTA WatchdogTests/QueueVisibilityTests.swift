//
//  QueueVisibilityTests.swift
//  IOTA WatchdogTests
//
//  Covers naming the run the orchestrator has assigned, and reporting the wait to get into it.
//
//  The orchestrator-response fixtures are real lines from
//  ~/Library/Logs/IOTA Train at Home/2026-09-19-cli.log with the hotkey replaced.
//  The `register.queue_state` fixture is NOT real: the worker advertises that capability on
//  every connection but has never emitted one on any log seen here, so its payload shape is a
//  guess. The parser therefore keeps the payload verbatim and the position stays nil unless a
//  number is genuinely present.
//

import XCTest
@testable import IOTA_Watchdog

@MainActor
final class QueueVisibilityTests: XCTestCase {

    private let parser = LogParser()

    // MARK: - Naming the run

    func testReadsRunIDFromRunConfigResponse() throws {
        let line = "[2026-09-19 01:45:07.908] [info]  2026-09-19 01:45:07.908 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/get_run_config; response: {'run_id': '4.12.16.1-tah', 'run_flags': {'test_flag': {'enabled': False}}}"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .runNamed(runID: "4.12.16.1-tah"))
    }

    func testReadsRunIDFromRunEpochResponse() throws {
        let line = "[2026-09-19 01:53:04.532] [info]  2026-09-19 01:53:04.532 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /common/get_run_epoch; response: {'run_id': '4.12.16.1-tah', 'epoch': 9}"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .runNamed(runID: "4.12.16.1-tah"))
    }

    /// The heartbeat response also carries a `run_id`. Reading it as the run name instead of
    /// as a heartbeat would cost the liveness signal the frozen rule depends on.
    func testHeartbeatResponseStaysAHeartbeat() throws {
        let line = "[2026-09-19 01:52:55.305] [info]  2026-09-19 01:52:55.305 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/heartbeat?expected_phase=training; response: {'run_id': '4.12.16.1-tah', 'layer': 1, 'epoch': 9}"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .heartbeat(phase: .training))
    }

    func testRecognisesTheWaitlistJoin() throws {
        let line = "[2026-09-19 01:52:49.247] [info]  2026-09-19 01:52:49.247 | INFO     | miner.pool.miner:register:197 - 🔄 Attempting to join registration waitlist for pool miner 5TESTAAA..."
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .joiningWaitlist)
    }

    /// The heartbeat also names the run, so the engine must not log one line per poll.
    func testRunNameIsRecordedOnceUntilItChanges() {
        let engine = WatchdogEngine()
        let named = { (runID: String, second: Int) in
            LogEvent(timestamp: Date(timeIntervalSince1970: TimeInterval(second)),
                     kind: .runNamed(runID: runID), rawLine: "")
        }
        engine.ingest([named("4.12.16.1-tah", 1), named("4.12.16.1-tah", 2), named("4.12.16.1-tah", 3)])
        let afterRepeats = engine.events.filter { $0.text.contains("assigned run") }.count
        XCTAssertEqual(afterRepeats, 1)
        XCTAssertEqual(engine.namedRunID, "4.12.16.1-tah")

        // A genuine move to another run is worth a line.
        engine.ingest([named("4.12.16.2-tah", 4)])
        XCTAssertEqual(engine.events.filter { $0.text.contains("assigned run") }.count, 2)
        XCTAssertEqual(engine.namedRunID, "4.12.16.2-tah")
    }

    /// The capability list at startup contains the bare string `'register.queue_state',` on its
    /// own continuation line. It must not be mistaken for an actual queue-state message.
    func testCapabilityListIsNotAQueueStateMessage() {
        XCTAssertNil(parser.parse("    'register.queue_state',"))
    }

    // MARK: - Queue position

    func testQueuePositionStaysNilWhenNoStateHasArrived() {
        XCTAssertNil(WatchdogEngine().queuePosition)
    }

    func testQueuePositionStaysNilWhenThePayloadHasNoPosition() {
        let engine = WatchdogEngine()
        let line = "[2026-09-19 01:52:54.974] [info] [Node Protocol Control] register.queue_state request received { state: 'waiting' }"
        engine.ingest([parser.parse(line)!])
        XCTAssertEqual(engine.lastQueueState, "{ state: 'waiting' }")
        XCTAssertNil(engine.queuePosition, "A payload without a number must not produce a position")
    }

    func testQueuePositionIsReadWhenThePayloadCarriesOne() {
        let engine = WatchdogEngine()
        let line = "[2026-09-19 01:52:54.974] [info] [Node Protocol Control] register.queue_state request received { position: 7, run_id: '4.12.16.2-tah' }"
        engine.ingest([parser.parse(line)!])
        XCTAssertEqual(engine.queuePosition, 7)
    }

    // MARK: - Occupancy

    func testOccupancyZipsTheParallelArrays() throws {
        // Real response from /v1/runs_occupancy, 2026-09-20.
        let json = """
        {"run_ids":["4.12.16.1-tah","4.12.16.7-tah"],"max_miners":[120,100],\
        "active_miners":[120,56],"slots_remaining":[0,44]}
        """
        let byRun = try JSONDecoder().decode(RunsOccupancyResponse.self, from: Data(json.utf8)).byRun

        let full = try XCTUnwrap(byRun["4.12.16.1-tah"])
        XCTAssertTrue(full.isFull)
        XCTAssertEqual(full.summary, "120 / 120 (full)")

        let open = try XCTUnwrap(byRun["4.12.16.7-tah"])
        XCTAssertFalse(open.isFull)
        XCTAssertEqual(open.summary, "56 / 100 (44 free)")
    }

    /// If the API ever returns arrays of differing lengths, drop the unbacked runs rather than
    /// pairing a run id with another run's numbers.
    func testOccupancySkipsRunsWithMissingValues() throws {
        let json = """
        {"run_ids":["a","b","c"],"max_miners":[120,100],"active_miners":[120,56],"slots_remaining":[0,44]}
        """
        let byRun = try JSONDecoder().decode(RunsOccupancyResponse.self, from: Data(json.utf8)).byRun
        XCTAssertEqual(Set(byRun.keys), ["a", "b"])
    }

    func testOccupancySurvivesAnEmptyResponse() throws {
        let byRun = try JSONDecoder().decode(RunsOccupancyResponse.self, from: Data("{}".utf8)).byRun
        XCTAssertTrue(byRun.isEmpty)
    }
}
