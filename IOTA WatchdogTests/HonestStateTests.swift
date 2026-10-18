//
//  HonestStateTests.swift
//  IOTA WatchdogTests
//
//  The state shown must match what the miner is actually doing. Two reports on 2026-10-18:
//  the Mac Mini read "Training" while in no run at all (out of its run since 05:40, stuck at the
//  queue's `confirmed` stage since 10:03), and the MacBook read "Settling" and then "Waiting for
//  network sync" while it was submitting activations.
//

import XCTest
@testable import IOTA_Watchdog

final class LaterQueueStatusParsingTests: XCTestCase {
    /// Real line, Mac Mini, 2026-10-18 10:42.
    func testReadsTheConfirmedStatus() throws {
        let line = "[2026-10-18 10:42:08.945] [info]  2026-10-18 10:42:08.945 | DEBUG    | subnet.common_api_client:orchestrator_request:89 - Successfully completed request to /miner/register/status/95f4f7d2-2fa7-4525-b441-fb2b406b559e; response: {'queue_id': '95f4f7d2-2fa7-4525-b441-fb2b406b559e', 'status': 'confirmed', 'position': None, 'poll_"
        XCTAssertEqual(try XCTUnwrap(LogParser().parse(line)).kind,
                       .registrationQueue(status: "confirmed", position: nil))
    }
}

@MainActor
final class HonestStateTests: XCTestCase {

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
    }

    private func running() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [90983], controlServerHealthy: true, hostAppRunning: true)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    /// The worker visibly alive (so nothing looks frozen) for `minutes`, with `extra` events
    /// every minute.
    private func alive(minutes: Int, every extra: [LogEventKind] = []) {
        for _ in 0..<minutes {
            clock.advance(60)
            engine.ingest(extra.map(event))
            engine.noteWorkerOutput(at: clock.current)
            engine.ingest(running())
        }
    }

    private func proposes(_ decision: WatchdogDecision) -> Bool {
        if case .proposeRestart = decision { return true }
        return false
    }

    // MARK: Later queue stages (Mac Mini)

    func testConfirmedAndProcessingAreStillPartOfTheQueue() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running()); clock.advance(11 * 60)
        engine.ingest([event(.registrationQueue(status: "queued", position: 216))])
        clock.advance(60)
        engine.ingest([event(.registrationQueue(status: "confirming", position: nil))])
        clock.advance(20)
        engine.ingest([event(.registrationQueue(status: "confirmed", position: nil))])
        alive(minutes: 3)
        XCTAssertTrue(engine.isQueued)
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .joiningRun(status: "confirmed"))
        XCTAssertEqual(engine.state.label, "Joining a run (confirmed)")
    }

    /// Past the queue the orchestrator flips confirmed ↔ processing every minute or so. The
    /// history gets one line for reaching that stage, not one per flip.
    func testFlippingBetweenLaterStagesIsRecordedOnce() {
        for status in ["queued", "confirming", "confirmed", "processing", "confirmed", "processing"] {
            engine.ingest([event(.registrationQueue(status: status, position: status == "queued" ? 216 : nil))])
            clock.advance(30)
        }
        let lines = engine.events.map(\.text).filter { $0.contains("queue") }
        XCTAssertEqual(lines, ["Joined the registration queue at #216",
                               "Through the queue; joining a run (confirming)"])
    }

    /// Peer counts change on every report; a held-back restart must not log a line per poll.
    func testTheLogKeyIgnoresPeerCounts() {
        XCTAssertEqual(WatchdogState.cutOffFromPeers(reachable: 3, total: 68).logKey,
                       WatchdogState.cutOffFromPeers(reachable: 2, total: 71).logKey)
    }

    func testTheLogKeyIgnoresTheLaterStage() {
        XCTAssertEqual(WatchdogState.joiningRun(status: "confirmed").logKey,
                       WatchdogState.joiningRun(status: "processing").logKey)
    }

    // MARK: "Training" must be earned

    /// The Mac Mini: last reported phase "training", hours ago; now in no run.
    func testAMinerInNoRunIsNotCalledTraining() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running()); clock.advance(11 * 60)
        engine.ingest([event(.submitActivation)])
        alive(minutes: 15, every: [.notRegistered])
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .notInRun)
    }

    func testNoEvidenceAndNoVerdictFromTheOrchestratorIsIdle() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running()); clock.advance(11 * 60)
        engine.ingest([event(.submitActivation)])
        alive(minutes: 15)
        _ = engine.evaluate()
        XCTAssertEqual(engine.state, .idle)
    }

    /// A miner in a run heartbeats several times a minute, which is enough between activations.
    func testHeartbeatsAreEnoughToCountAsTraining() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running()); clock.advance(11 * 60)
        engine.ingest([event(.submitActivation)])
        alive(minutes: 15, every: [.heartbeat(phase: .training)])
        _ = engine.evaluate()
        XCTAssertEqual(engine.state, .training)
    }

    // MARK: Real work outranks "settling" and "waiting" (MacBook)

    /// Restarted at 10:37, first activation 10:43: "Training" from then on, not "Settling".
    func testWorkDuringTheStartupGraceShowsAsTraining() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running())
        alive(minutes: 5)
        XCTAssertEqual({ _ = engine.evaluate(); return engine.state }(), .settling(reason: "just started"))
        clock.advance(60)
        engine.ingest([event(.submitActivation)])
        alive(minutes: 1, every: [.heartbeat(phase: .training)])
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .training)
    }

    /// The grace still protects against restarts: showing "Training" is presentation only.
    func testTheGraceStillBlocksRestartsWhileShowingTraining() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running())
        clock.advance(60)
        engine.ingest([event(.submitActivation)])
        clock.advance(60)
        engine.ingest(ProcessSnapshot(workerPIDs: [], controlServerHealthy: false, hostAppRunning: true))
        engine.ingest(ProcessSnapshot(workerPIDs: [], controlServerHealthy: false, hostAppRunning: true))
        XCTAssertFalse(proposes(engine.evaluate()), "the worker-gone rule waits until the grace ends")
    }

    /// Joined after the last sync, so in theory waiting; but activations are flowing.
    func testAMinerAlreadySubmittingIsNotWaitingForSync() {
        engine.ingest([event(.processSpawned)]); engine.ingest(running())
        engine.ingestAPI(activationCount: 11468, reachable: true,
                         lastSyncAt: clock.current.addingTimeInterval(-3600),
                         nextSyncAt: clock.current.addingTimeInterval(14 * 60))
        engine.ingest([event(.registered(prefix: "5TESTAAA"))])
        clock.advance(60)
        XCTAssertTrue(engine.isWaitingForSync)
        engine.ingest([event(.submitActivation)])
        XCTAssertFalse(engine.isWaitingForSync)
    }
}
