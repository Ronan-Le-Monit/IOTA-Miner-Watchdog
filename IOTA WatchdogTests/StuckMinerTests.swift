//
//  StuckMinerTests.swift
//  IOTA WatchdogTests
//
//  Reproduces a miner that sat stuck for six hours on 2026-09-05 while the watchdog watched and
//  did nothing. Two faults let it through, and both are covered here.
//

import XCTest
@testable import IOTA_Watchdog

@MainActor
final class StuckMinerTests: XCTestCase {

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
        ProcessSnapshot(workerPIDs: [7520], controlServerHealthy: true,
                        hostAppRunning: true, hostAppPID: 900)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    /// Fault 1: the API's next-sync estimate slides forward on every poll, so "wait until the
    /// next sync" never expired. The real log shows the estimate walking 13:32, 14:25, 15:17,
    /// 16:10, 17:03, 17:56, 18:48 while the activation count sat at 3000 the whole time.
    func testASlidingSyncEstimateCannotExcuseAMinerForever() {
        let lastSync = clock.current
        clock.advance(10 * 60)
        engine.ingest([event(.processSpawned), event(.registered(prefix: "5TESTCCC"))])
        engine.ingest(running())

        // Six hours, with the estimate always about 50 minutes ahead and nothing else happening.
        for _ in 0..<72 {
            clock.advance(5 * 60)
            engine.ingest([event(.chatter)])
            engine.ingest(running())
            engine.ingestAPI(activationCount: 3000, reachable: true,
                             lastSyncAt: lastSync,
                             nextSyncAt: clock.current.addingTimeInterval(50 * 60))
        }

        XCTAssertFalse(engine.isWaitingForSync,
                       "the excuse must expire once the cap is passed")
        guard case .proposeRestart = engine.evaluate() else {
            return XCTFail("a miner idle for six hours must be restarted, got \(engine.evaluate())")
        }
    }

    /// A genuine short wait is still honoured.
    func testAShortWaitForTheNextSyncIsStillHonoured() {
        let lastSync = clock.current
        clock.advance(20 * 60)
        engine.ingest([event(.processSpawned), event(.registered(prefix: "5TESTCCC"))])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 3000, reachable: true,
                         lastSyncAt: lastSync,
                         nextSyncAt: clock.current.addingTimeInterval(40 * 60))

        clock.advance(11 * 60)
        engine.ingest([event(.chatter)])
        engine.ingest(running())
        XCTAssertTrue(engine.isWaitingForSync)
        XCTAssertEqual(engine.evaluate(), .doNothing)
    }

    /// Fault 2: the miner reset and re-registered every few minutes, and both of those counted
    /// as progress, so the no-progress clock was reset before it could ever reach an hour.
    func testResettingAndRegisteringAreNotProgress() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)

        let baselineBefore = engine.progressBaseline
        clock.advance(5 * 60)
        engine.ingest([event(.resettingState)])
        clock.advance(60)
        engine.ingest([event(.registered(prefix: "5TESTCCC"))])
        engine.ingest(running())

        XCTAssertEqual(engine.progressBaseline, baselineBefore,
                       "recovery attempts must not reset the progress clock")
    }

    /// A training tick is emitted as part of each registration, so it cannot count either.
    func testATrainingTickIsNotProgress() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)
        let baselineBefore = engine.progressBaseline

        clock.advance(5 * 60)
        engine.ingest([event(.trainingState(.trainingTick))])
        XCTAssertEqual(engine.progressBaseline, baselineBefore)

        // An actual activation does count.
        clock.advance(60)
        engine.ingest([event(.submitActivation)])
        XCTAssertEqual(engine.progressBaseline, clock.current)
    }

    /// The loop itself is now recognised, so it is caught in minutes rather than an hour.
    /// Real timings: reset 18:14:28, registered 18:15:27, reset 18:21:10, registered 18:21:28.
    func testARepeatedResetLoopIsCaughtQuickly() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 3000, reachable: true)
        clock.advance(11 * 60)

        for _ in 0..<3 {
            engine.ingest([event(.resettingState)])
            clock.advance(60)
            engine.ingest([event(.registered(prefix: "5TESTCCC"))])
            clock.advance(5 * 60)
            engine.ingest([event(.chatter)])
            engine.ingest(running())
        }

        XCTAssertGreaterThanOrEqual(engine.recentResetCount, 3)
        guard case .proposeRestart(let trigger) = engine.evaluate() else {
            return XCTFail("a reset loop must be caught, got \(engine.evaluate())")
        }
        guard case .resetLoop(let count, _) = trigger else {
            return XCTFail("expected resetLoop, got \(trigger)")
        }
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    /// A reset loop is broken behaviour whatever the sync schedule claims.
    func testAResetLoopIsNotExcusedByAPendingSync() {
        let lastSync = clock.current
        clock.advance(10 * 60)
        engine.ingest([event(.processSpawned), event(.registered(prefix: "5TESTCCC"))])
        engine.ingest(running())
        clock.advance(11 * 60)

        for _ in 0..<3 {
            engine.ingest([event(.resettingState)])
            clock.advance(60)
            engine.ingest([event(.registered(prefix: "5TESTCCC"))])
            clock.advance(4 * 60)
            engine.ingest(running())
            engine.ingestAPI(activationCount: 3000, reachable: true,
                             lastSyncAt: lastSync,
                             nextSyncAt: clock.current.addingTimeInterval(50 * 60))
        }

        guard case .proposeRestart(let trigger) = engine.evaluate() else {
            return XCTFail("expected a restart despite the pending sync")
        }
        guard case .resetLoop = trigger else { return XCTFail("expected resetLoop, got \(trigger)") }
    }

    /// One reset is ordinary self-recovery and must be left alone.
    func testASingleResetIsNotATrigger() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 3000, reachable: true)
        clock.advance(11 * 60)

        engine.ingest([event(.resettingState)])
        clock.advance(60)
        engine.ingest([event(.registered(prefix: "5TESTCCC"))])
        engine.ingest(running())

        XCTAssertEqual(engine.evaluate(), .doNothing)
    }

    /// A miner that recovers and starts training again clears the loop count.
    func testTrainingAgainClearsTheResetCount() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)
        engine.ingest([event(.resettingState), event(.resettingState)])
        engine.ingest([event(.submitActivation)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 3001, reachable: true)
        _ = engine.evaluate()
        XCTAssertEqual(engine.recentResetCount, 0)
    }
}
