//
//  SettingsAndSuppressionTests.swift
//  IOTA WatchdogTests
//
//  Regressions for the two faults that let a stopped miner sit there unrestarted on
//  2026-09-04: settings that did not persist, and a restart that was blocked without
//  saying so anywhere.
//

import XCTest
import Combine
@testable import IOTA_Watchdog

@MainActor
final class WatchdogSettingsTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testDefaultsAreSafeOnFirstRun() {
        let settings = WatchdogSettings(fileURL: fileURL)
        XCTAssertFalse(settings.autoRestartEnabled, "must not restart anything until asked")
        XCTAssertEqual(settings.noProgressMinutes, 60)
        XCTAssertEqual(settings.frozenMinutes, 5)
        XCTAssertTrue(settings.localPrefixOverride.isEmpty, "no manual hotkey until the user sets one")
        // Deliberately not asserting a particular hotkey: it is detected from whatever wallet
        // this machine has. An earlier version hardcoded one here and only passed on the
        // author's Mac.
        XCTAssertEqual(settings.localPrefix, settings.detectedHotkey?.prefix)
    }

    /// The original bug: a toggle in the menu did not survive a relaunch, because a stale sandbox
    /// container intercepted this bundle's UserDefaults domain.
    func testChangesSurviveARelaunch() {
        let first = WatchdogSettings(fileURL: fileURL)
        first.autoRestartEnabled = true
        first.noProgressMinutes = 25

        let second = WatchdogSettings(fileURL: fileURL)
        XCTAssertTrue(second.autoRestartEnabled, "the toggle must persist")
        XCTAssertEqual(second.noProgressMinutes, 25)
    }

    func testEngineConfigFollowsTheSettings() {
        let settings = WatchdogSettings(fileURL: fileURL)
        settings.autoRestartEnabled = true
        settings.frozenMinutes = 3
        settings.noProgressMinutes = 30

        let config = settings.engineConfig
        XCTAssertTrue(config.autoRestartEnabled)
        XCTAssertEqual(config.frozenThreshold, 180)
        XCTAssertEqual(config.noProgressThreshold, 1800)
    }

    /// `@Published` publishes from `willSet`, so anything that re-reads the property inside a
    /// sink sees the value from before the change. That is what left the engine with
    /// auto-restart off after the user switched it on. `engineConfig` must never be read that
    /// way; reading it after the assignment must show the new value.
    func testEngineConfigReadInsideAPublishedSinkIsStale() {
        let settings = WatchdogSettings(fileURL: fileURL)
        var seenInsideSink: Bool?
        let cancellable = settings.$autoRestartEnabled.sink { _ in
            seenInsideSink = settings.engineConfig.autoRestartEnabled
        }
        settings.autoRestartEnabled = true
        cancellable.cancel()

        XCTAssertEqual(seenInsideSink, false,
                       "documents the willSet trap that caused the bug")
        XCTAssertTrue(settings.engineConfig.autoRestartEnabled,
                      "reading after the change gives the correct value")
    }
}

@MainActor
final class RestartSuppressionTests: XCTestCase {

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
        ProcessSnapshot(workerPIDs: [48007], controlServerHealthy: true,
                        hostAppRunning: true, hostAppPID: 89051)
    }

    private func workerGone() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [], controlServerHealthy: false,
                        hostAppRunning: true, hostAppPID: 89051)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    private func settleIntoTraining() {
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        clock.advance(11 * 60)
        engine.ingest([event(.submitActivation)])
        engine.ingest(running())
        _ = engine.evaluate()
    }

    /// The real failure: the miner stopped, the watchdog saw it, and nothing was reported.
    func testStoppedMinerWithAutoRestartOffReportsWhyItIsNotRestarting() {
        engine.config.autoRestartEnabled = false
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())

        guard case .suppressedRestart(let trigger, let reason) = engine.evaluate() else {
            return XCTFail("a blocked restart must be reported, not silently dropped")
        }
        XCTAssertEqual(trigger, .shutdown)
        XCTAssertTrue(reason.contains("switched off"), "got: \(reason)")
        XCTAssertTrue(engine.events.contains { $0.text.contains("Would restart") })
    }

    /// Reported once, not on every poll.
    func testSuppressionIsReportedOncePerTrigger() {
        engine.config.autoRestartEnabled = false
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())
        _ = engine.evaluate()

        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .doNothing, "must not repeat the same reason each poll")
    }

    /// Turning the switch on must make the very next evaluation act.
    func testEnablingAutoRestartMakesTheNextEvaluationPropose() {
        engine.config.autoRestartEnabled = false
        settleIntoTraining()
        engine.ingest([event(.shutdownComplete)])
        clock.advance(30)
        engine.ingest(workerGone())
        _ = engine.evaluate()

        engine.config.autoRestartEnabled = true
        engine.ingest(workerGone())
        XCTAssertEqual(engine.evaluate(), .proposeRestart(.shutdown))
    }

    /// After the watchdog itself restarts there may be no progress mark in the miner's log,
    /// because only about 90 minutes of it survives and the tailer starts from the tail. The
    /// no-progress rule must still be able to fire, measured from when the worker was first seen.
    func testNoProgressStillFiresWithoutAnyProgressMark() {
        // No log events at all: the watchdog has just started and the miner is already idle.
        engine.ingestAPI(activationCount: 500, reachable: true)
        engine.ingest(running())
        _ = engine.evaluate()
        XCTAssertNotNil(engine.progressBaseline, "must fall back to first-seen-running")

        for _ in 0..<70 {
            clock.advance(60)
            engine.ingest([event(.chatter)])          // alive, but never any progress
            engine.ingestAPI(activationCount: 500, reachable: true)
            engine.ingest(running())
        }

        guard case .proposeRestart(let trigger) = engine.evaluate() else {
            return XCTFail("an idle miner with no progress mark must still be caught")
        }
        guard case .noProgress = trigger else { return XCTFail("expected noProgress, got \(trigger)") }
    }

    /// A miner that starts fresh is measured from its start, not from an older baseline.
    func testMinerStartResetsTheBaseline() {
        engine.ingest(running())
        _ = engine.evaluate()
        clock.advance(30 * 60)
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        XCTAssertEqual(engine.progressBaseline, clock.current,
                       "a start resets the clock so the grace period governs")
    }

    /// A miner that registers mid-epoch is idle by design until the run's next full sync.
    /// Restarting there is worse than waiting: it re-registers, misses that sync too, and waits
    /// for the one after. Reproduces the real timings from 2026-09-04/05.
    func testIdleAfterRegisteringMidEpochWaitsForTheNextSyncInsteadOfRestarting() {
        let lastSync = clock.current                       // the run synced ...
        clock.advance(80 * 60)                             // ... 80 minutes ago
        let nextSync = lastSync.addingTimeInterval(125 * 60)

        // The miner registers now, i.e. after that sync, then reaches training and goes quiet.
        engine.ingest([event(.processSpawned), event(.registered(prefix: "5TESTAAA"))])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 1196, reachable: true,
                         lastSyncAt: lastSync, nextSyncAt: nextSync)

        clock.advance(11 * 60)                             // past the startup grace
        engine.ingest([event(.chatter)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 1196, reachable: true,
                         lastSyncAt: lastSync, nextSyncAt: nextSync)

        XCTAssertTrue(engine.isWaitingForSync)
        XCTAssertEqual(engine.evaluate(), .doNothing, "must not restart while queued for a sync")
        guard case .waitingForSync = engine.state else {
            return XCTFail("expected waitingForSync, got \(engine.state)")
        }

        // Even well past the normal no-progress threshold, it keeps waiting.
        for _ in 0..<70 {
            clock.advance(60)
            engine.ingest([event(.chatter)])
            engine.ingest(running())
            engine.ingestAPI(activationCount: 1196, reachable: true,
                             lastSyncAt: lastSync, nextSyncAt: nextSync)
        }
        // The sync estimate plus its grace has now passed, so the rule is live again.
        guard case .proposeRestart = engine.evaluate() else {
            return XCTFail("once the sync has come and gone, an idle miner must be restarted")
        }
    }

    /// A miner that registered *before* the last sync has no excuse: it should have been training.
    func testRegisteredBeforeTheLastSyncIsNotExcused() {
        let registered = clock.current
        clock.advance(30 * 60)
        let lastSync = clock.current                       // sync happened after registration
        let nextSync = clock.current.addingTimeInterval(120 * 60)

        engine.ingest([event(.processSpawned), event(.registered(prefix: "5TESTAAA"))])
        _ = registered
        engine.ingest(running())
        engine.ingestAPI(activationCount: 500, reachable: true,
                         lastSyncAt: lastSync, nextSyncAt: nextSync)
        XCTAssertFalse(engine.isWaitingForSync,
                       "registration predates the sync, so it is not waiting for one")
    }

    /// The registration line is usually gone from the miner's short log by the time it matters,
    /// so the miner's start time (which survives in main.log) has to stand in for it.
    func testWaitingForSyncWorksFromTheStartTimeAlone() {
        let lastSync = clock.current
        clock.advance(60 * 60)
        let nextSync = lastSync.addingTimeInterval(125 * 60)

        // Only a spawn event: no registration line survived the log rotation.
        engine.ingest([event(.processSpawned)])
        engine.ingest(running())
        engine.ingestAPI(activationCount: 1196, reachable: true,
                         lastSyncAt: lastSync, nextSyncAt: nextSync)

        XCTAssertNotNil(engine.joinedRunAt)
        XCTAssertTrue(engine.isWaitingForSync,
                      "a miner started after the last sync is queued for the next one")
    }

    func testBudgetExhaustionIsAlsoReported() {
        settleIntoTraining()
        for _ in 0..<3 {
            engine.recordRestartStarted()
            clock.advance(11 * 60)
        }
        engine.ingest([event(.shutdownComplete)])
        engine.ingest(workerGone())

        guard case .suppressedRestart(_, let reason) = engine.evaluate() else {
            return XCTFail("an exhausted budget must be reported")
        }
        XCTAssertTrue(reason.contains("last hour"), "got: \(reason)")
    }
}
