//
//  WatchdogEngineTests.swift
//  IOTA WatchdogTests
//
//  The decision rules. A fake clock drives time so every threshold is exercised exactly.
//

import XCTest
@testable import IOTA_Watchdog

@MainActor
final class WatchdogEngineTests: XCTestCase {

    /// Controllable clock.
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

    // MARK: Fixtures

    private func running() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [48007], controlServerHealthy: true,
                        hostAppRunning: true, hostAppPID: 89051)
    }

    private func workerGone() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [], controlServerHealthy: false,
                        hostAppRunning: true, hostAppPID: 89051)
    }

    private func appGone() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [], controlServerHealthy: false, hostAppRunning: false)
    }

    private func event(_ kind: LogEventKind, at offset: TimeInterval = 0) -> LogEvent {
        LogEvent(timestamp: clock.current.addingTimeInterval(offset), kind: kind, rawLine: "")
    }

    /// Brings the engine to a healthy, past-grace training state.
    private func settleIntoTraining() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 100, reachable: true)
        clock.advance(11 * 60)                       // past the startup grace
        engine.ingest([event(.submitActivation)])
        engine.ingestAPI(activationCount: 101, reachable: true)
        engine.ingest(running())
        engine.evaluate()
    }

    // MARK: Baseline

    func testUnknownUntilFirstProbe() {
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .unknown)
    }

    func testHealthyTrainingIsNoAction() {
        settleIntoTraining()
        XCTAssertEqual(engine.state, .training)
        XCTAssertEqual(engine.evaluate(), .doNothing)
    }

    func testNonTrainingPhaseIsReportedButNotAProblem() {
        settleIntoTraining()
        engine.ingest([event(.layerPhaseChange(actual: .weightsUploading, expected: .training))])
        engine.ingest(running())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .otherPhase(.weightsUploading))
        XCTAssertFalse(engine.state.isProblem)
    }

    /// The miner logs the move into weights_uploading but almost never the move back, so an
    /// activation must be enough to conclude it is training again. Observed live on 2026-09-04:
    /// 11 activations arrived after the last phase-change line, with no "back to training" line.
    func testActivationAfterAPhaseChangeReturnsStateToTraining() {
        settleIntoTraining()
        engine.ingest([event(.layerPhaseChange(actual: .weightsUploading, expected: .training))])
        engine.ingest(running())
        _ = engine.evaluate()
        XCTAssertEqual(engine.state, .otherPhase(.weightsUploading))

        clock.advance(120)
        engine.ingest([event(.submitActivation)])
        engine.ingest(running())
        _ = engine.evaluate()
        XCTAssertEqual(engine.state, .training, "an activation proves training resumed")
    }

    // MARK: Grace periods

    func testStartupGraceSuppressesEverything() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(workerGone())
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .settling(reason: "just started"))
    }

    func testWakeGraceSuppressesFreezeDetection() {
        settleIntoTraining()
        engine.lastWakeAt = clock.current
        clock.advance(6 * 60)                        // long enough to look frozen
        engine.ingest(running())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .settling(reason: "Mac just woke"))
    }

    func testFreezeIsDetectedOnceTheWakeGraceExpires() {
        settleIntoTraining()
        engine.lastWakeAt = clock.current
        clock.advance(11 * 60)
        engine.ingest(running())
        guard case .proposeRestart(let trigger) = engine.evaluate() else {
            return XCTFail("expected a restart proposal, got \(engine.evaluate())")
        }
        guard case .frozen = trigger else { return XCTFail("expected frozen, got \(trigger)") }
    }

    // MARK: Rule 1 — fatal / shutdown fast path

    func testFatalErrorProposesRestartImmediatelyEvenInStartupGrace() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(60)                            // still well inside the startup grace
        engine.ingest([event(.criticalError(reason: "pseudo gradients for miner 5TESTAAA has NaNs")),
                       event(.shutdownComplete)])
        engine.ingest(workerGone())

        guard case .proposeRestart(let trigger) = engine.evaluate() else {
            return XCTFail("expected a restart proposal")
        }
        XCTAssertEqual(trigger, .fatalError(reason: "pseudo gradients for miner 5TESTAAA has NaNs"))
        XCTAssertEqual(engine.state, .stopped)
    }

    /// The exact sequence from 2026-09-04: critical error, shutdown, process exit, and the app
    /// then sat idle for 86 minutes. One poll after the exit must already propose a restart.
    func testRealCrashSequenceProposesRestartWithoutWaitingForDebounce() {
        settleIntoTraining()
        engine.ingest([
            event(.criticalError(reason: "pseudo gradients for miner 5TESTAAA has NaNs")),
            event(.shutdownComplete, at: 19),
            event(.processExited(code: "0", signal: "null"), at: 20)
        ])
        clock.advance(30)
        engine.ingest(workerGone())                  // a single observation is enough here

        guard case .proposeRestart = engine.evaluate() else {
            return XCTFail("a crashed miner must be caught on the first poll")
        }
    }

    func testCleanShutdownWithoutFatalErrorStillProposesRestart() {
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.shutdown))
    }

    /// A stop the user asked for must never be undone automatically.
    func testUserInitiatedStopIsNeverRestarted() {
        settleIntoTraining()
        engine.ingest([event(.controlStopRequested), event(.shutdownComplete, at: 1)])
        clock.advance(30)
        engine.ingest(workerGone())
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .stoppedByUser)
    }

    // MARK: Rule 2 — stopped debounce

    func testStoppedNeedsTwoConsecutiveObservations() {
        settleIntoTraining()
        clock.advance(60)

        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing, "one missed observation is not enough")
        XCTAssertEqual(engine.state, .settling(reason: "worker not seen once"))

        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.stopped))
    }

    func testWorkerSeenAgainResetsTheDebounce() {
        settleIntoTraining()
        clock.advance(60)
        engine.ingest(workerGone())
        engine.ingest(running())
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing)
    }

    func testHostAppGoneJustLaunchesIt() {
        settleIntoTraining()
        clock.advance(60)
        engine.ingest(appGone())
        XCTAssertEqual(engine.evaluate(), .launchHostApp)
    }

    // MARK: Rule 4 — no progress

    func testNoProgressRequiresBothLocalAndAPIEvidence() {
        settleIntoTraining()

        // Local logs go quiet on activations but chatter keeps the log fresh, while the API
        // still reports rising activations: not a stall.
        for _ in 0..<70 {
            clock.advance(60)
            engine.ingest([event(.chatter)])
            engine.ingestAPI(activationCount: (engine.apiActivationCount ?? 0) + 1, reachable: true)
            engine.ingest(running())
        }
        XCTAssertEqual(engine.evaluate(), .doNothing, "the API says it is still progressing")

        // Now the API count freezes as well.
        let frozenCount = engine.apiActivationCount
        for _ in 0..<70 {
            clock.advance(60)
            engine.ingest([event(.chatter)])
            engine.ingestAPI(activationCount: frozenCount, reachable: true)
            engine.ingest(running())
        }
        guard case .proposeRestart(let trigger) = engine.evaluate() else {
            return XCTFail("expected a no-progress proposal")
        }
        guard case .noProgress = trigger else { return XCTFail("expected noProgress, got \(trigger)") }
    }

    /// Activation gaps of up to 45 minutes are normal during weight upload and merging.
    func testFortyFiveMinuteActivationGapIsNotAStall() {
        settleIntoTraining()
        for _ in 0..<45 {
            clock.advance(60)
            engine.ingest([event(.chatter)])
            engine.ingest(running())
        }
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertFalse(engine.state.isProblem)
    }

    // MARK: Network outage guard

    func testNetworkOutageSuppressesFreezeRestart() {
        settleIntoTraining()
        engine.ingest([event(.orchestratorUnreachable),
                       event(.orchestratorUnreachable, at: 1),
                       event(.orchestratorUnreachable, at: 2)])
        clock.advance(6 * 60)
        engine.ingest(running())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .networkOutage)
    }

    func testUnreachableAPIAlsoCountsAsOutage() {
        settleIntoTraining()
        engine.ingestAPI(activationCount: nil, reachable: false)
        clock.advance(6 * 60)
        engine.ingest(running())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .networkOutage)
    }

    /// An outage must not stop us restarting a process that is actually gone.
    func testOutageDoesNotSuppressTheStoppedRule() {
        settleIntoTraining()
        engine.ingest([event(.orchestratorUnreachable),
                       event(.orchestratorUnreachable, at: 1),
                       event(.orchestratorUnreachable, at: 2)])
        clock.advance(60)
        engine.ingest(workerGone())
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.stopped))
    }

    // MARK: Budget and backoff

    func testBudgetAllowsThreeRestartsPerHourThenNeedsAttention() {
        settleIntoTraining()
        for index in 0..<3 {
            XCTAssertTrue(engine.canRestart(), "restart \(index) should be allowed")
            engine.recordRestartStarted()
            XCTAssertFalse(engine.canRestart(), "the minimum spacing blocks an immediate retry")
            clock.advance(11 * 60)                   // clears the minimum spacing
        }
        XCTAssertFalse(engine.canRestart(), "the fourth restart in an hour must be refused")

        engine.ingest([event(.shutdownComplete)])
        engine.ingest(workerGone())

        let decision = engine.evaluate()
        if case .proposeRestart = decision {
            XCTFail("must not restart once the budget is spent")
        }
        guard case .suppressedRestart = decision else {
            return XCTFail("expected the exhausted budget to be reported, got \(decision)")
        }
        guard case .needsAttention = engine.state else {
            return XCTFail("expected needsAttention, got \(engine.state)")
        }
    }

    func testMinimumSpacingBlocksBackToBackRestarts() {
        settleIntoTraining()
        engine.recordRestartStarted()
        clock.advance(5 * 60)
        XCTAssertFalse(engine.canRestart(), "5 minutes is inside the 10 minute minimum spacing")
        clock.advance(6 * 60)
        XCTAssertTrue(engine.canRestart())
    }

    func testBudgetRecoversAfterAnHour() {
        settleIntoTraining()
        for _ in 0..<3 {
            engine.recordRestartStarted()
            clock.advance(11 * 60)
        }
        XCTAssertFalse(engine.canRestart())
        clock.advance(60 * 60)
        XCTAssertTrue(engine.canRestart())
    }

    // MARK: Proposal hygiene

    func testTheSameTriggerIsProposedOnlyOnce() {
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.shutdown))
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing, "must not propose the same restart twice")
    }

    func testCancellingStopsAutomaticRestartsUntilResumed() {
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())
        _ = engine.evaluate()

        engine.recordRestartCancelled()
        XCTAssertEqual(engine.state, .stoppedByUser)

        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing)

        engine.resumeAutomaticRestarts()
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.shutdown))
    }

    /// After a successful restart the miner starts again, which must clear the user-stopped and
    /// shutdown state so later problems are caught normally.
    func testStartClearsPreviousStopState() {
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(workerGone())
        _ = engine.evaluate()
        engine.recordRestartCancelled()

        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        XCTAssertEqual(engine.state, .settling(reason: "just started"))
    }

    /// With the switch off nothing is restarted, but the reason is reported rather than the
    /// engine going quiet on a stopped miner.
    func testAutoRestartDisabledNeverProposes() {
        engine.config.autoRestartEnabled = false
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())

        let decision = engine.evaluate()
        if case .proposeRestart = decision {
            XCTFail("must not restart while the switch is off")
        }
        guard case .suppressedRestart(_, let reason) = decision else {
            return XCTFail("expected the block to be reported, got \(decision)")
        }
        XCTAssertTrue(reason.contains("switched off"), "got: \(reason)")
    }

    func testPauseSuppressesEvaluationUntilItExpires() {
        settleIntoTraining()
        engine.pause(for: 3600)
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(workerGone())
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing)
        guard case .paused = engine.state else { return XCTFail("expected paused") }

        clock.advance(3601)
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.shutdown))
    }

    // MARK: History

    func testHistoryIsCappedAndKeepsTheNewest() {
        for index in 0..<60 {
            engine.ingest([event(.processSpawned)])
            clock.advance(TimeInterval(index))
        }
        XCTAssertLessThanOrEqual(engine.events.count, 50)
        XCTAssertEqual(engine.events.last?.text, "Miner started")
    }
}
