//
//  RegistrationQueueTests.swift
//  IOTA WatchdogTests
//
//  On 2026-10-11 the watchdog restarted a miner it called frozen. The miner was healthy: it had
//  spent two hours in the orchestrator's registration queue, where the only lines it writes are
//  queue polls the parser did not recognise. These tests cover reading the queue (and showing
//  the position) and judging "frozen" on any worker output.
//
//  Fixtures are real lines from ~/Library/Logs/IOTA Train at Home/2026-10-11-cli.log and
//  2026-10-07-cli.log. They contain no hotkeys.
//

import XCTest
@testable import IOTA_Watchdog

private enum Fixture {
    static let queued38 = "[2026-10-11 23:29:31.571] [info]  2026-10-11 23:29:31.570 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/register/status/645d3974-fe6c-4ae3-a373-79e62c9f0c50; response: {'queue_id': '645d3974-fe6c-4ae3-a373-79e62c9f0c50', 'status': 'queued', 'position': 38, 'poll_after"
    static let expired = "[2026-10-11 21:29:33.787] [info]  2026-10-11 21:29:33.787 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/register/status/a84c71bc-f99d-4ca6-9930-9fa97332ab80; response: {'queue_id': 'a84c71bc-f99d-4ca6-9930-9fa97332ab80', 'status': 'expired', 'position': None, 'poll_af"
    static let joined1029 = "[2026-10-11 21:15:19.340] [info]  2026-10-11 21:15:19.340 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/register; response: {'queue_id': 'a84c71bc-f99d-4ca6-9930-9fa97332ab80', 'status': 'queued', 'position': 1029, 'poll_aft"
    static let queueStateWarning = "[2026-10-11 23:29:43.590] [info]  2026-10-11 23:29:43.590 | WARNING  | miner.utils.node_control_mixin:register_set_queue_state:221 - register_set_queue_state exhausted retries (3): POST /register/queue_state failed 503: {\"detail\":\"unsupported: No handler for register.queue_state\"}"
    static let notRegistered = "[2026-10-07 02:00:48.942] [info]  2026-10-07 02:00:48.942 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/get_run_config; response: {'error_name': 'EntityNotRegisteredError', 'error_dict': {'message': 'Entity not registered', 'name'"
    static let electronProtocol = "[2026-10-08 10:32:22.469] [info]  [protocol] reconnecting in 649ms (attempt 2) undefined"
}

final class RegistrationQueueParsingTests: XCTestCase {

    private let parser = LogParser()

    func testReadsThePositionFromAQueueStatusPoll() throws {
        let event = try XCTUnwrap(parser.parse(Fixture.queued38))
        XCTAssertEqual(event.kind, .registrationQueue(status: "queued", position: 38))
    }

    func testReadsThePositionFromTheJoinResponse() throws {
        let event = try XCTUnwrap(parser.parse(Fixture.joined1029))
        XCTAssertEqual(event.kind, .registrationQueue(status: "queued", position: 1029))
    }

    func testAnExpiredPlaceHasNoPosition() throws {
        let event = try XCTUnwrap(parser.parse(Fixture.expired))
        XCTAssertEqual(event.kind, .registrationQueue(status: "expired", position: nil))
    }

    func testEntityNotRegisteredIsRecognised() throws {
        let event = try XCTUnwrap(parser.parse(Fixture.notRegistered))
        XCTAssertEqual(event.kind, .notRegistered)
    }

    func testWorkerLinesAreToldApartFromHostLines() {
        let worker = LogParser.splitPrefix(Fixture.queueStateWarning)!.1
        let host = LogParser.splitPrefix(Fixture.electronProtocol)!.1
        XCTAssertTrue(LogParser.isWorkerLine(worker))
        XCTAssertFalse(LogParser.isWorkerLine(host))
    }

    /// The 503 warning is still ignored as an event, but it is proof the worker is alive.
    func testAnIgnoredWorkerLineStillCountsAsSignOfLife() {
        var stream = LogLineStream()
        XCTAssertNil(stream.consume(Fixture.queueStateWarning))
        XCTAssertNotNil(stream.lastWorkerLineAt)
    }

    func testHostLinesAreNotWorkerLife() {
        var stream = LogLineStream()
        _ = stream.consume(Fixture.electronProtocol)
        XCTAssertNil(stream.lastWorkerLineAt)
    }
}

@MainActor
final class RegistrationQueueBehaviourTests: XCTestCase {

    private final class Clock {
        var current = Date(timeIntervalSince1970: 1_780_000_000)
        func advance(_ seconds: TimeInterval) { current.addTimeInterval(seconds) }
    }

    private var clock: Clock!
    private var engine: WatchdogEngine!

    override func setUp() async throws {
        clock = Clock()
        let clock = self.clock!
        engine = WatchdogEngine(config: WatchdogConfig()) { clock.current }
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)
    }

    private func running() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [84978], controlServerHealthy: true, hostAppRunning: true)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    private func proposes(_ decision: WatchdogDecision) -> Bool {
        if case .proposeRestart = decision { return true }
        return false
    }

    /// The incident itself: two hours queued, nothing recognised, and it must not be "frozen".
    func testTwoHoursInTheQueueIsNotFrozen() {
        engine.ingest([event(.registrationQueue(status: "queued", position: 1029))])
        for position in [341, 494, 293, 260, 186, 266, 38] {
            clock.advance(17 * 60)
            engine.ingest([event(.registrationQueue(status: "queued", position: position))])
            engine.ingest(running())
        }
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .queued(position: 38))
        XCTAssertEqual(engine.queuePosition, 38)
    }

    /// Unrecognised worker output is enough to rule out a freeze, queue or no queue.
    func testWorkerOutputTheParserIgnoresStillRulesOutAFreeze() {
        engine.ingest([event(.chatter)])
        for _ in 0..<12 {
            clock.advance(10 * 60)
            engine.noteWorkerOutput(at: clock.current)
            engine.ingest(running())
        }
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertNotEqual(engine.state, .frozen)
    }

    /// A queue that stops reporting is no excuse: once the worker has really gone quiet, the
    /// frozen rule is back.
    func testAQueueThatStopsReportingLapses() {
        engine.ingest([event(.registrationQueue(status: "queued", position: 38))])
        engine.noteWorkerOutput(at: clock.current)
        clock.advance(11 * 60)
        engine.ingest(running())
        let decision = engine.evaluate()
        guard case .proposeRestart(.frozen) = decision else {
            return XCTFail("expected the frozen rule after the queue went silent, got \(decision)")
        }
    }

    /// Being assigned a run ends the queue.
    func testRegistrationEndsTheQueue() {
        engine.ingest([event(.registrationQueue(status: "queued", position: 38))])
        clock.advance(60)
        engine.ingest([event(.registered(prefix: "5TESTAAA"))])
        engine.ingest(running())
        XCTAssertFalse(engine.isQueued)
        XCTAssertNil(engine.queuePosition)
        XCTAssertNotEqual(engine.state, .queued(position: 38))
    }

    /// While queued the miner is in no run, so an old run name must not be shown.
    func testQueueingForgetsTheOldRun() {
        engine.ingest([event(.runNamed(runID: "4.12.16.24-tah"))])
        XCTAssertEqual(engine.namedRunID, "4.12.16.24-tah")
        engine.ingest([event(.registrationQueue(status: "queued", position: 1029))])
        XCTAssertNil(engine.namedRunID)
    }

    func testNotRegisteredForgetsTheOldRunToo() {
        engine.ingest([event(.runNamed(runID: "4.12.16.24-tah"))])
        engine.ingest([event(.notRegistered)])
        XCTAssertNil(engine.namedRunID)
    }

    /// A position change is news for the menu, not for the history list.
    func testOnlyStatusChangesAreRecorded() {
        engine.ingest([event(.registrationQueue(status: "queued", position: 1029))])
        engine.ingest([event(.registrationQueue(status: "queued", position: 341))])
        engine.ingest([event(.registrationQueue(status: "queued", position: 38))])
        engine.ingest([event(.registrationQueue(status: "expired", position: nil))])
        let queueLines = engine.events.filter { $0.text.contains("queue") || $0.text.contains("Queue") }
        XCTAssertEqual(queueLines.map(\.text),
                       ["Joined the registration queue at #1029",
                        "Queue place expired; the miner joins again"])
    }

    func testTheLogKeyIgnoresThePosition() {
        XCTAssertEqual(WatchdogState.queued(position: 38).logKey, WatchdogState.queued(position: 266).logKey)
        XCTAssertEqual(WatchdogState.queued(position: 38).label, "Queued — position #38")
    }
}
