//
//  PeerLossTests.swift
//  IOTA WatchdogTests
//
//  Rule 4, added in 1.6: a miner cut off from the other miners. On 2026-10-16 the MacBook's
//  miner process reached 0 of 36 peers for hours while alive, busy and heartbeating, and every
//  finished activation was dropped. The Mac Mini on the same router stayed at 56–81%. Restarting
//  the miner fixed it at once. Healthy after the fix: 47–72% of peers, 0 dropped in 80 minutes.
//
//  Fixtures are real lines from ~/Library/Logs/IOTA Train at Home/2026-10-16-cli.log and the
//  Mac Mini's log of the same day, with peer hotkeys replaced by 5PEERAAA.
//

import XCTest
@testable import IOTA_Watchdog

private enum Fixture {
    static let cutOff = "[2026-10-16 17:17:09.155] [info]  2026-10-16 17:17:09.155 | WARNING  | miner.new_miner:_broadcast_peer_status:585 - Broadcast peer status: 0/36 ok, 36 unreachable in 5046ms | errors: TimeoutError=36 | sample: [5PEERAAA (relay=y, direct=5) -> TimeoutError: ; 5PEERAAA (relay=y, direct=2) -> TimeoutError: ]"
    static let healthy = "[2026-10-16 17:37:00.995] [info]  2026-10-16 17:37:00.995 | WARNING  | miner.new_miner:_broadcast_peer_status:585 - Broadcast peer status: 17/24 ok, 7 unreachable in 5002ms | errors: TimeoutError=7 | sample: [5PEERAAA (relay=y, direct=5) -> TimeoutError: ]"
    static let dropped = "[2026-10-16 14:34:28.780] [info]  2026-10-16 14:34:28.780 | ERROR    | miner.training.activation_publisher:_process_outbound_item:638 - Failed to send forward activation 60cc5272-0ac5-4377-aa22-9631e78eeb0a (connect timeout after 5s), dropping (tries exhausted) | peer=5PEERAAA layer=1 relay=y direct=4 | req=- | conn=- open=- sen"
}

final class PeerLossParsingTests: XCTestCase {

    private let parser = LogParser()

    func testReadsAPeerStatusWithNobodyReachable() throws {
        XCTAssertEqual(try XCTUnwrap(parser.parse(Fixture.cutOff)).kind,
                       .peerStatus(reachable: 0, total: 36))
    }

    func testReadsAHealthyPeerStatus() throws {
        XCTAssertEqual(try XCTUnwrap(parser.parse(Fixture.healthy)).kind,
                       .peerStatus(reachable: 17, total: 24))
    }

    /// An ERROR line, but not a fatal one: the miner carries on.
    func testRecognisesADroppedActivation() throws {
        XCTAssertEqual(try XCTUnwrap(parser.parse(Fixture.dropped)).kind, .forwardActivationDropped)
    }
}

@MainActor
final class PeerLossBehaviourTests: XCTestCase {

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
        ProcessSnapshot(workerPIDs: [62557], controlServerHealthy: true, hostAppRunning: true)
    }

    private func event(_ kind: LogEventKind) -> LogEvent {
        LogEvent(timestamp: clock.current, kind: kind, rawLine: "")
    }

    private func proposes(_ decision: WatchdogDecision) -> Bool {
        if case .proposeRestart(.peersLost) = decision { return true }
        return false
    }

    /// `minutes` of reports every 10 s, with the worker visibly alive; `dropEvery` and
    /// `submitEvery` are the seconds between dropped and submitted activations (0 for none).
    private func run(minutes: Int, reachable: Int, total: Int, dropEvery: Int = 60, submitEvery: Int = 0) {
        for second in stride(from: 0, to: minutes * 60, by: 10) {
            clock.advance(10)
            engine.ingest([event(.peerStatus(reachable: reachable, total: total))])
            if dropEvery > 0, second % dropEvery == 0 { engine.ingest([event(.forwardActivationDropped)]) }
            if submitEvery > 0, second % submitEvery == 0 { engine.ingest([event(.submitActivation)]) }
            engine.noteWorkerOutput(at: clock.current)
            engine.ingest(running())
        }
    }

    /// The incident: nobody reachable, work dropped, for longer than the window.
    func testAMinerCutOffFromItsPeersIsRestarted() {
        run(minutes: 16, reachable: 0, total: 36)
        XCTAssertTrue(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .cutOffFromPeers(reachable: 0, total: 36))
    }

    /// 2/28, the direct-cable test just before the restart, is still cut off.
    func testAFewReachablePeersIsStillCutOff() {
        run(minutes: 16, reachable: 2, total: 28)
        XCTAssertTrue(proposes(engine.evaluate()))
    }

    /// A healthy miner, at the lowest healthy level measured.
    func testAHealthyMinerIsLeftAlone() {
        run(minutes: 30, reachable: 16, total: 35, dropEvery: 0)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// A network change knocks the count to zero for under a minute. That is not this.
    func testABriefDropAfterANetworkChangeIsIgnored() {
        run(minutes: 10, reachable: 18, total: 36, dropEvery: 0)
        run(minutes: 1, reachable: 0, total: 36)
        run(minutes: 10, reachable: 16, total: 36, dropEvery: 0)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// Few peers, but work still being handed on: the miner is not wasting its time.
    func testFewPeersWhileWorkStillFlowsIsLeftAlone() {
        run(minutes: 20, reachable: 1, total: 36, dropEvery: 0, submitEvery: 30)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// 1.7: the Mac Mini on 2026-10-18. Cut off, it dropped only 2 activations and then simply
    /// stopped working. 1.6 needed 3 drops and never fired; the orchestrator dropped the miner
    /// 40 minutes later and it queued for 4 h 22 min.
    func testAMinerThatStoppedWorkingWhileCutOffIsRestarted() {
        engine.ingest([event(.forwardActivationDropped)])
        run(minutes: 1, reachable: 7, total: 60, dropEvery: 0)
        engine.ingest([event(.forwardActivationDropped)])
        run(minutes: 15, reachable: 2, total: 69, dropEvery: 0)
        XCTAssertTrue(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .cutOffFromPeers(reachable: 2, total: 69))
        XCTAssertEqual(engine.peerLossEvidence(at: clock.current)?.submitted, 0)
    }

    /// One submission inside the window is still work, so "no work" needs none at all.
    func testASingleSubmissionMeansWorkHasNotStopped() {
        run(minutes: 8, reachable: 2, total: 69, dropEvery: 0)
        engine.ingest([event(.submitActivation)])
        run(minutes: 8, reachable: 2, total: 69, dropEvery: 0)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// One healthy report inside the window breaks the pattern.
    func testOneHealthyReportInTheWindowIsEnoughToHold() {
        run(minutes: 8, reachable: 0, total: 36)
        run(minutes: 0, reachable: 0, total: 36)
        clock.advance(10)
        engine.ingest([event(.peerStatus(reachable: 20, total: 36))])
        run(minutes: 8, reachable: 0, total: 36)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// A watchdog that has just started cannot see fifteen minutes back.
    func testAShortHistoryIsNotEnough() {
        run(minutes: 6, reachable: 0, total: 36)
        XCTAssertFalse(proposes(engine.evaluate()))
    }

    /// If the internet itself is down, peers are unreachable for an obvious reason.
    func testANetworkOutageHoldsInstead() {
        engine.ingestAPI(activationCount: 2000, reachable: false)
        run(minutes: 16, reachable: 0, total: 36)
        XCTAssertFalse(proposes(engine.evaluate()))
        XCTAssertEqual(engine.state, .networkOutage)
    }

    /// One restart is the cure for a stuck process. If it did not reconnect, the cause is
    /// elsewhere, and repeating it is what 2–4 October looked like.
    func testASecondRestartIsHeldBackIfTheFirstDidNotReconnect() {
        run(minutes: 16, reachable: 0, total: 36)
        XCTAssertTrue(proposes(engine.evaluate()))
        engine.recordRestartStarted()
        engine.ingest([event(.minerStarting)])
        clock.advance(11 * 60)

        run(minutes: 16, reachable: 0, total: 36)
        let decision = engine.evaluate()
        guard case .suppressedRestart(.peersLost, let reason) = decision else {
            return XCTFail("expected the second restart to be held back, got \(decision)")
        }
        XCTAssertTrue(reason.contains("already failed"))
        XCTAssertEqual(engine.state, .cutOffFromPeers(reachable: 0, total: 36))
    }

    /// …and a restart that did reconnect re-arms the rule for the future.
    func testASuccessfulRestartRearmsTheRule() {
        run(minutes: 16, reachable: 0, total: 36)
        _ = engine.evaluate()
        engine.recordRestartStarted()
        engine.ingest([event(.minerStarting)])
        clock.advance(60)
        run(minutes: 1, reachable: 16, total: 28, dropEvery: 0)
        XCTAssertNil(engine.peerLossRestartAt)
        XCTAssertTrue(engine.events.contains { $0.text.hasPrefix("Back in contact") })
    }

    /// A new process starts with new connections; the old one's reports do not count against it.
    func testANewProcessStartsWithACleanSlate() {
        run(minutes: 14, reachable: 0, total: 36)
        engine.ingest([event(.minerStarting)])
        XCTAssertTrue(engine.peerReports.isEmpty)
        XCTAssertTrue(engine.droppedActivationTimes.isEmpty)
        XCTAssertTrue(engine.submittedActivationTimes.isEmpty)
    }

    func testTheMenuShowsTheLatestReport() {
        run(minutes: 1, reachable: 18, total: 36, dropEvery: 0)
        let latest = try? XCTUnwrap(engine.latestPeerReport)
        XCTAssertEqual(latest?.reachable, 18)
        XCTAssertEqual(latest?.fraction, 0.5)
    }
}
