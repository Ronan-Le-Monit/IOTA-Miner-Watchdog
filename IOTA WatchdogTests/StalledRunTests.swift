//
//  StalledRunTests.swift
//  IOTA WatchdogTests
//
//  A run can die while the miner is perfectly healthy. Restarting cannot fix that, because the
//  orchestrator puts the miner straight back into the same run. Measured on 2026-09-06: one run
//  had last synced 63.9 hours earlier while nine others had all synced within the hour.
//

import XCTest
@testable import IOTA_Watchdog

final class StalledRunDetectionTests: XCTestCase {

    private func observation(ownAge: TimeInterval, others: [TimeInterval]) -> APIObservation {
        var all = others + [ownAge]
        all.sort()
        return APIObservation(reachable: true, activationCount: 3000,
                              runSyncAge: ownAge,
                              medianSyncAge: all[all.count / 2])
    }

    /// The real numbers from the day it was found.
    func testTheRealStalledRunIsDetected() {
        let healthy: [TimeInterval] = [0.2, 0.3, 0.3, 0.4, 0.4, 0.5, 0.5, 0.7, 0.8].map { $0 * 3600 }
        let observed = observation(ownAge: 63.9 * 3600, others: healthy)
        XCTAssertTrue(observed.runAppearsStalled)
    }

    /// A healthy run, even the slowest of them, must never be flagged.
    func testHealthyRunsAreNotFlagged() {
        let healthy: [TimeInterval] = [0.2, 0.3, 0.3, 0.4, 0.4, 0.5, 0.5, 0.7].map { $0 * 3600 }
        XCTAssertFalse(observation(ownAge: 0.8 * 3600, others: healthy).runAppearsStalled)
    }

    /// A run a couple of hours behind is slow, not dead. Syncs are one to two hours apart.
    func testASlowRunIsNotCalledStalled() {
        let others: [TimeInterval] = [0.5, 0.6, 0.9, 1.1, 1.4].map { $0 * 3600 }
        XCTAssertFalse(observation(ownAge: 2.5 * 3600, others: others).runAppearsStalled)
    }

    /// If every run is behind, the network is having a bad day and no single run is at fault.
    func testWhenAllRunsLagNoneIsSingledOut() {
        let others: [TimeInterval] = [8, 9, 10, 11, 12].map { $0 * 3600 }
        XCTAssertFalse(observation(ownAge: 10 * 3600, others: others).runAppearsStalled)
    }

    func testMissingDataNeverFlags() {
        XCTAssertFalse(APIObservation(reachable: true).runAppearsStalled)
        XCTAssertFalse(APIObservation(reachable: true, runSyncAge: 99 * 3600).runAppearsStalled)
    }
}

@MainActor
final class StalledRunBehaviourTests: XCTestCase {

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
        ProcessSnapshot(workerPIDs: [7520], controlServerHealthy: true, hostAppRunning: true)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    /// The whole point: a dead run must not produce restarts, however stuck the miner looks.
    func testADeadRunIsReportedRatherThanRestarted() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)

        // Hours of looping and no progress, which would otherwise trip two separate rules.
        for _ in 0..<12 {
            engine.ingest([event(.resettingState)])
            clock.advance(10 * 60)
            engine.ingest([event(.registered(prefix: "5TESTCCC"))])
            engine.ingest(running())
            engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: 63.9)
        }

        let decision = engine.evaluate()
        if case .proposeRestart = decision {
            XCTFail("restarting rejoins the same dead run, so it must not be proposed")
        }
        guard case .runStalled(let hours) = engine.state else {
            return XCTFail("expected runStalled, got \(engine.state)")
        }
        XCTAssertEqual(hours, 63.9, accuracy: 0.01)
        XCTAssertTrue(engine.state.isProblem, "the user should still be told")
    }

    /// And it says why, once, rather than going quiet.
    func testItExplainsWhyItIsNotRestarting() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)
        engine.ingest([event(.chatter)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: 63.9)

        guard case .suppressedRestart(_, let reason) = engine.evaluate() else {
            return XCTFail("expected the reason to be reported")
        }
        XCTAssertTrue(reason.contains("rejoins the same run"), "got: \(reason)")
    }

    /// Once the run recovers, normal behaviour resumes.
    func testNormalRulesResumeWhenTheRunRecovers() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)
        engine.ingest(running())
        engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: 63.9)
        _ = engine.evaluate()

        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(ProcessSnapshot(workerPIDs: [], controlServerHealthy: false,
                                      hostAppRunning: true))
        engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: nil)
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.shutdown))
    }
}
