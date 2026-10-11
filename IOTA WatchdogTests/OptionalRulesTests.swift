//
//  OptionalRulesTests.swift
//  IOTA WatchdogTests
//
//  Since 2026-10-11 three rules are optional and off by default: no progress, the reset loop,
//  and holding restarts for a stalled run or a pending network sync. The rules that remain on
//  act on direct evidence only. Tests of the optional rules themselves opt in through
//  `WatchdogConfig.withOptionalRules`, exactly as a user would in the menu.
//

import XCTest
@testable import IOTA_Watchdog

extension WatchdogConfig {
    /// A configuration with every optional rule switched on.
    static var withOptionalRules: WatchdogConfig {
        var config = WatchdogConfig()
        config.noProgressRuleEnabled = true
        config.resetLoopRuleEnabled = true
        config.holdForRunStateEnabled = true
        return config
    }
}

@MainActor
final class OptionalRulesTests: XCTestCase {

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
        clock.advance(11 * 60)   // past the startup grace
    }

    private func running() -> ProcessSnapshot {
        ProcessSnapshot(workerPIDs: [1620], controlServerHealthy: true, hostAppRunning: true)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    private func proposes(_ decision: WatchdogDecision) -> Bool {
        if case .proposeRestart = decision { return true }
        return false
    }

    func testTheOptionalRulesAreOffByDefault() {
        let config = WatchdogConfig()
        XCTAssertFalse(config.noProgressRuleEnabled)
        XCTAssertFalse(config.resetLoopRuleEnabled)
        XCTAssertFalse(config.holdForRunStateEnabled)
    }

    /// Hours without an activation, the API agreeing, a log full of chatter: left alone.
    func testNoProgressDoesNotRestartByDefault() {
        engine.ingestAPI(activationCount: 4791, reachable: true)
        for _ in 0..<16 {
            clock.advance(5 * 60)
            engine.ingest([event(.chatter)])
            engine.ingest(running())
            engine.ingestAPI(activationCount: 4791, reachable: true)
        }
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertNil(engine.noProgressDeadline, "no restart time to promise when the rule is off")
    }

    func testAResetLoopDoesNotRestartByDefault() {
        engine.ingestAPI(activationCount: 3000, reachable: true)
        for _ in 0..<12 {
            engine.ingest([event(.resettingState)])
            clock.advance(10 * 60)
            engine.ingest([event(.registered(prefix: "5TESTAAA"))])
            engine.ingest(running())
            engine.ingestAPI(activationCount: 3000, reachable: true)
        }
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// With the hold off, a dead run no longer protects a frozen miner from a restart.
    func testAStalledRunNoLongerHoldsBackTheFrozenRule() {
        engine.ingest([event(.chatter)])
        engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: 63.9)
        clock.advance(6 * 60)
        engine.ingest(running())
        let decision = engine.evaluate()
        guard case .proposeRestart(.frozen) = decision else {
            return XCTFail("expected the frozen rule to fire, got \(decision)")
        }
    }

    /// …but it is still reported, rather than the menu claiming the miner is training.
    func testAStalledRunIsStillShownWhenNothingElseIsWrong() {
        engine.ingest([event(.chatter)])
        engine.ingestAPI(activationCount: 3000, reachable: true, runStalledForHours: 63.9)
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .runStalled(hours: 63.9))
    }

    /// Switching a rule on in the menu brings it back exactly as before.
    func testSwitchingNoProgressOnRestoresIt() {
        var config = WatchdogConfig()
        config.noProgressRuleEnabled = true
        engine.config = config
        engine.ingestAPI(activationCount: 4791, reachable: true)
        for _ in 0..<16 {
            clock.advance(5 * 60)
            engine.ingest([event(.chatter)])
            engine.ingest(running())
            engine.ingestAPI(activationCount: 4791, reachable: true)
        }
        XCTAssertTrue(proposes(engine.evaluate()))
    }

    // MARK: Settings

    func testSettingsDefaultToOffAndPersist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-optional-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = WatchdogSettings(fileURL: url)
        XCTAssertFalse(first.noProgressRuleEnabled)
        XCTAssertFalse(first.resetLoopRuleEnabled)
        XCTAssertFalse(first.holdForRunStateEnabled)
        XCTAssertFalse(first.engineConfig.noProgressRuleEnabled)

        first.resetLoopRuleEnabled = true
        let second = WatchdogSettings(fileURL: url)
        XCTAssertTrue(second.resetLoopRuleEnabled)
        XCTAssertTrue(second.engineConfig.resetLoopRuleEnabled)
        XCTAssertFalse(second.noProgressRuleEnabled)
    }

    /// A settings file written by 1.3, which knows nothing of these switches, loads them as off.
    func testAnOlderSettingsFileLoadsWithTheRulesOff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"autoRestartEnabled": true, "noProgressMinutes": 60}"#.utf8).write(to: url)

        let settings = WatchdogSettings(fileURL: url)
        XCTAssertTrue(settings.autoRestartEnabled)
        XCTAssertFalse(settings.noProgressRuleEnabled)
        XCTAssertFalse(settings.holdForRunStateEnabled)
    }
}
