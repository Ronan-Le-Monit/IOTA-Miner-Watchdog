//
//  ShutdownRestartTests.swift
//  IOTA WatchdogTests
//
//  Rule 1: a miner that is no longer training gets restarted. The timeline is the Mac Mini's,
//  2026-10-08 (hotkey 5FjAQL4Y):
//
//    10:29:30  ❌ Critical error in run_miner: pseudo gradients for miner … has NaNs
//    10:29:35  Cleaning up miner on shutdown...
//    10:32:11  🛑 Miner shutdown complete
//    10:42:47  🚀 Starting miner 🚀           — ten idle minutes, until someone intervened
//

import XCTest
@testable import IOTA_Watchdog

@MainActor
final class ShutdownRestartTests: XCTestCase {

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
        // A miner that has been training happily for a while.
        engine.ingest([event(.processSpawned)])
        engine.ingest(worker(running: true))
        clock.advance(30 * 60)
        engine.ingest([event(.submitActivation)])
    }

    private func worker(running: Bool) -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: running ? [1620] : [], controlServerHealthy: running,
                        hostAppRunning: true)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    private func proposes(_ decision: WatchdogDecision) -> Bool {
        if case .proposeRestart = decision { return true }
        return false
    }

    /// The real sequence: no restart during the cleanup, a restart once it has finished.
    func testTheMacMiniSequenceRestartsAfterCleanupNotDuringIt() {
        engine.ingest([event(.criticalError(reason: "pseudo gradients for miner 5TESTAAA has NaNs"))])

        // 10:30:30 and 10:32:00 — still cleaning up. Restarting here would cut that short.
        clock.advance(60)
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .settling(reason: "miner shutting down"))
        clock.advance(90)
        XCTAssertFalse(proposes(engine.evaluate()))

        // 10:32:11 — shutdown complete, the process is still listed.
        clock.advance(11)
        engine.ingest([event(.shutdownComplete)])
        XCTAssertFalse(proposes(engine.evaluate()), "allow the process a moment to exit")

        // 10:33:12 — it has not exited. Restart anyway rather than wait forever.
        clock.advance(61)
        let decision = engine.evaluate()
        guard case .proposeRestart(.fatalError) = decision else {
            return XCTFail("expected a restart for the fatal error, got \(decision)")
        }
    }

    /// The old rule's blind spot: shutdown complete, but a worker process stays listed.
    func testShutdownWithALingeringWorkerProcessIsRestarted() {
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(worker(running: true))
        clock.advance(61)
        XCTAssertTrue(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .stopped)
    }

    /// Once the process has gone there is nothing left to wait for.
    func testShutdownWithTheWorkerGoneRestartsAtOnce() {
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(worker(running: false))
        XCTAssertTrue(proposes(engine.evaluate()))
    }

    /// A fatal error that never produces the shutdown line is still acted on, after the cap.
    func testAFatalErrorWithoutAShutdownLineIsRestartedAfterTheCleanupCap() {
        engine.ingest([event(.criticalError(reason: "boom"))])
        clock.advance(4 * 60)
        XCTAssertFalse(proposes(engine.evaluate()))
        clock.advance(61)
        XCTAssertTrue(proposes(engine.evaluate()))
    }

    /// A shut-down miner is not training, so a stalled run is no reason to leave it alone.
    func testAShutdownIsRestartedEvenInAStalledRun() {
        engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: 63.9)
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(worker(running: false))
        XCTAssertTrue(proposes(engine.evaluate()))
    }

    /// Nor is having only just started: a miner that dies within ten minutes still gets help.
    func testAShutdownDuringTheStartupGraceIsRestarted() {
        engine.ingest([event(.minerStarting)])
        clock.advance(3 * 60)
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(worker(running: false))
        XCTAssertTrue(proposes(engine.evaluate()))
    }

    /// Pressing Stop Training must never be undone, even while the process is winding down.
    func testAStopYouAskedForIsNeverUndone() {
        engine.ingest([event(.controlStopRequested)])
        clock.advance(20)
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(worker(running: true))
        clock.advance(10 * 60)
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .stoppedByUser)
    }

    /// If the miner comes back by itself, the shutdown is history.
    func testAShutdownFollowedByAStartIsForgotten() {
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest([event(.minerStarting)])
        engine.ingest(worker(running: true))
        clock.advance(2 * 60)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// The switch in the menu is still the final word.
    func testWithAutomaticRestartOffItIsReportedNotActedOn() {
        var config = WatchdogConfig()
        config.autoRestartEnabled = false
        let clock = self.clock!
        engine = WatchdogEngine(config: config) { clock.current }
        engine.ingest([event(.processSpawned)])
        clock.advance(30 * 60)
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(worker(running: false))
        guard case .suppressedRestart(_, let reason) = engine.evaluate() else {
            return XCTFail("expected a suppressed restart")
        }
        XCTAssertTrue(reason.contains("switched off"))
    }
}
