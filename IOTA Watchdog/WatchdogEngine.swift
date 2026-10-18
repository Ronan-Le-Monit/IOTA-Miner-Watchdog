//
//  WatchdogEngine.swift
//  IOTA Watchdog
//
//  Decides whether the miner is healthy, and when it is not, whether to restart it.
//
//  Everything the engine knows comes from three places: log events (LogTailer), local process
//  probes (ProcessProbe) and the public API (APIProbe). It owns no timers and does no I/O of its
//  own — `evaluate(now:)` is a pure-ish function of accumulated state, which is what makes the
//  rules testable.
//

import Foundation
import Combine

// MARK: - Configuration

/// Thresholds. Defaults come from measurements on the real logs; see the comments.
struct WatchdogConfig: Equatable {
    /// How often the engine is polled.
    var pollInterval: TimeInterval = 30
    /// No log output for this long, while the process is alive, means frozen.
    /// A healthy miner writes 40–690 lines per minute; the longest non-sleep silence
    /// observed over three days was 63 s.
    var frozenThreshold: TimeInterval = 5 * 60
    /// No progress at all for this long means stuck. Gaps between activations of up to 45 min
    /// are normal during weight upload and partition merging, so this is deliberately generous.
    var noProgressThreshold: TimeInterval = 60 * 60
    /// Grace after a start: registration alone takes about 6 minutes.
    var startupGrace: TimeInterval = 10 * 60
    /// Grace after the Mac wakes: the miner has to re-register.
    var wakeGrace: TimeInterval = 10 * 60
    /// The worker must look gone for this many consecutive polls before we call it stopped.
    var stoppedConfirmations = 2
    /// After `Miner shutdown complete`, how long to let the worker process exit on its own before
    /// restarting anyway. The worker host can outlive its training loop.
    var shutdownExitWait: TimeInterval = 60
    /// After a fatal error, how long to wait for the miner to finish cleaning up and log
    /// `Miner shutdown complete`. Measured on the Mac Mini, 2026-10-08: 2 min 41 s.
    var fatalCleanupWait: TimeInterval = 5 * 60

    /// Peer-loss rule: restart when, for this long, every peer-status report reached at most
    /// `peerLossMaxFraction` of the other miners, and finished work was being dropped.
    /// Measured 2026-10-16: a healthy miner reaches 47–81% of its peers; the stuck one 0–7%
    /// for hours; a network change dips to 0 for under a minute. The window sits well clear.
    var peerLossWindow: TimeInterval = 15 * 60
    var peerLossMaxFraction: Double = 0.15
    /// At least this many reports inside the window, so the evidence is continuous.
    var peerLossMinReports = 10
    /// Proof the time is wasted: at least this many activations dropped inside the window,
    /// *or* none submitted at all. The second half was added in 1.7 after the Mac Mini, on
    /// 2026-10-18, lost its peers and simply stopped working, dropping only 2 activations in
    /// the process. 1.6 never fired; the orchestrator dropped the miner 40 minutes later and it
    /// queued for 4 h 22 min. The three cut-offs before it, caught and restarted while still
    /// registered, each rejoined their run with no queue.
    var peerLossMinDropped = 3
    /// After a restart for peer loss that did not reconnect, wait this long before another.
    var peerLossRetryAfter: TimeInterval = 2 * 60 * 60
    /// Restarts allowed in any rolling hour.
    var maxRestartsPerHour = 3
    /// Never restart twice within this window.
    var minRestartSpacing: TimeInterval = 10 * 60
    /// Seconds the user gets to cancel an automatic restart.
    var confirmationCountdown: TimeInterval = 60
    /// Longest the miner is excused for "waiting for the next sync".
    ///
    /// The API's next-sync estimate slides forward on every poll, so a rule of the form
    /// "wait until the estimate" never expires. Seen in the wild: a miner excused for six hours
    /// while the estimate walked from 13:32 to 18:48 and its activation count never moved.
    var syncWaitCap: TimeInterval = 90 * 60
    /// A miner that keeps resetting and re-registering *for a long time* is broken, not busy.
    ///
    /// Joining a run legitimately involves looping: when a batch of runs goes live, miners can
    /// cycle through reset and registration for twenty to sixty minutes and then get in fine.
    /// Restarting during that would be a false positive that costs the run, so the rule needs a
    /// sustained loop, not a burst — and the API has to agree that nothing is being credited.
    var resetLoopWindow: TimeInterval = 90 * 60
    var resetLoopThreshold = 5
    /// The loop must have been running at least this long. Longer than the observed join period.
    var resetLoopMinimumDuration: TimeInterval = 60 * 60
    /// Orchestrator-unreachable events within this window that mean "the network is down".
    var outageWindow: TimeInterval = 10 * 60
    var outageEventThreshold = 3
    /// Hotkey prefix of the miner on this Mac. Nil when it could not be identified.
    var localPrefix: String?
    /// Master switch for automatic restarts.
    var autoRestartEnabled = true

    // Optional rules, all off by default (2026-10-11). Each relies on inference — about progress,
    // about join loops, about the state of the run — and each has been wrong in practice: a
    // miner stuck `initializing` was restarted ~73 times to no effect, and a dead run kept the
    // watchdog holding off for days. The rules that remain on are the ones with direct evidence:
    // the miner said it shut down, its process vanished, its log went silent, the app quit.

    /// Restart after `noProgressThreshold` without an activation, confirmed by the API.
    var noProgressRuleEnabled = false
    /// Restart a sustained reset/re-register loop, confirmed by the API.
    var resetLoopRuleEnabled = false
    /// Hold restarts while the run has stalled or the miner is waiting for the next network
    /// sync. When off, both are still *shown*, they just no longer block a restart.
    var holdForRunStateEnabled = false
}

// MARK: - State

/// What the watchdog believes is happening, in priority order for display.
enum WatchdogState: Equatable {
    /// Training normally.
    case training
    /// Running but in a non-training phase (weights uploading, merging partitions).
    case otherPhase(MinerPhase)
    /// Recently started or recently woken; too early to judge.
    case settling(reason: String)
    /// Registered mid-epoch, so it cannot train until the run's next full synchronisation.
    /// Restarting here is actively harmful: it would miss that sync and wait for the one after.
    case waitingForSync(until: Date)
    /// Waiting in the orchestrator's registration queue for a place in a run. Healthy, and
    /// quiet by nature: the miner only polls its queue status. Never restarted for that.
    case queued(position: Int?)
    /// Alive and working, but unable to reach the other miners, so its work is being dropped.
    case cutOffFromPeers(reachable: Int, total: Int)
    /// Through the queue and being placed in a run: `confirming`, `confirmed`, `processing`.
    /// Still in no run, and still not something a restart can speed up.
    case joiningRun(status: String)
    /// Running, but the orchestrator says it is in no run (`EntityNotRegistered`).
    case notInRun
    /// Running, but nothing shows it is training: no activation and no heartbeat recently.
    case idle
    /// The miner is not running.
    case stopped
    /// The user stopped it, or cancelled a restart. No automatic action.
    case stoppedByUser
    /// The process is alive but has written nothing for a long time.
    case frozen
    /// Alive and writing, but no training progress.
    case notProgressing
    /// The orchestrator or the network is unreachable; a restart would not help.
    case networkOutage
    /// The whole training run has stopped syncing, not just this miner. Restarting is futile:
    /// the orchestrator puts the miner straight back into the same run.
    case runStalled(hours: Double)
    /// Restart budget exhausted; needs a human.
    case needsAttention(reason: String)
    /// Watchdog paused by the user.
    case paused(until: Date)
    /// Not enough information yet (just launched).
    case unknown

    /// Whether this state should read as a problem in the UI.
    var isProblem: Bool {
        switch self {
        case .stopped, .frozen, .notProgressing, .needsAttention, .cutOffFromPeers: return true
        case .training, .otherPhase, .settling, .waitingForSync, .queued, .joiningRun,
             .notInRun, .idle, .stoppedByUser,
             .networkOutage, .paused, .unknown:
            return false
        case .runStalled:
            // Worth the user's attention, but not something this app can fix.
            return true
        }
    }
}

/// Why the engine wants to restart. Drives the wording of the confirmation window.
enum RestartTrigger: Equatable {
    case fatalError(reason: String)
    case shutdown
    case stopped
    case frozen(logAge: TimeInterval)
    case noProgress(since: TimeInterval)
    case resetLoop(count: Int, minutes: Int)
    /// Kept free of the live counts on purpose: a suppressed restart is reported once per
    /// distinct trigger, and counts that change every report would repeat it every poll.
    case peersLost(minutes: Int)

    var title: String {
        switch self {
        case .fatalError: return "IOTA miner crashed"
        case .shutdown: return "IOTA miner stopped"
        case .stopped: return "IOTA miner is not running"
        case .frozen: return "IOTA miner appears frozen"
        case .noProgress: return "IOTA miner is not making progress"
        case .resetLoop: return "IOTA miner keeps resetting"
        case .peersLost: return "IOTA miner cannot reach the other miners"
        }
    }

    var detail: String {
        switch self {
        case .fatalError(let reason): return "Fatal error: \(reason)"
        case .shutdown: return "The miner logged a clean shutdown."
        case .stopped: return "The worker process is gone while the app is running."
        case .frozen(let age):
            return "No log output for \(Int(age / 60)) minutes while the process is alive."
        case .noProgress(let since):
            return "No training progress for \(Int(since / 60)) minutes."
        case .resetLoop(let count, let minutes):
            return "Reset and re-registered \(count) times in \(minutes) minutes without training."
        case .peersLost(let minutes):
            return "For \(minutes) minutes it reached almost none of the other miners, "
                + "and its work was being dropped or had stopped."
        }
    }
}

/// A decision the engine reached on one evaluation.
enum WatchdogDecision: Equatable {
    case doNothing
    /// Show the countdown window, then restart unless cancelled.
    case proposeRestart(RestartTrigger)
    /// The host app is not running at all: just launch it.
    case launchHostApp
    /// A restart was warranted but something blocked it. Reported so the log never goes silent
    /// on a stopped miner, which is exactly what made the first real stall hard to explain.
    case suppressedRestart(RestartTrigger, reason: String)
}

/// One thing worth showing in the menu's history.
struct WatchdogEvent: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let text: String
    let isNotable: Bool
}

// MARK: - Engine

/// Accumulates evidence and answers "what should happen now?".
///
/// Not an actor: it is driven from the main actor by a timer and holds only plain state.
@MainActor
final class WatchdogEngine: ObservableObject {

    @Published private(set) var state: WatchdogState = .unknown
    @Published private(set) var events: [WatchdogEvent] = []
    @Published var config: WatchdogConfig

    // Evidence from the logs.
    private(set) var lastLogEventAt: Date?
    /// When the Python worker last wrote any line, recognised by the parser or not.
    private(set) var lastWorkerOutputAt: Date?
    /// The latest registration-queue status from the orchestrator (`queued`, `expired`, …).
    private(set) var queueStatus: String?
    /// The position that came with it.
    private(set) var reportedQueuePosition: Int?
    /// When the queue status was last reported. The miner polls about once a minute.
    private(set) var queueStatusAt: Date?

    /// One `Broadcast peer status` report.
    struct PeerReport: Equatable {
        let at: Date
        let reachable: Int
        let total: Int
        var fraction: Double { total > 0 ? Double(reachable) / Double(total) : 0 }
    }
    /// Recent peer reports from the current miner process, oldest first.
    private(set) var peerReports: [PeerReport] = []
    /// When finished activations were dropped for want of a reachable peer.
    private(set) var droppedActivationTimes: [Date] = []
    /// When activations were submitted, for the "no work at all" half of the peer-loss proof.
    private(set) var submittedActivationTimes: [Date] = []
    /// Set when a restart for peer loss begins; cleared once a healthy report shows the
    /// restart worked. While set, a second peer-loss restart is held back.
    private(set) var peerLossRestartAt: Date?

    /// The latest peer report, if it is recent enough to describe the miner now.
    var latestPeerReport: PeerReport? {
        guard let last = peerReports.last, now().timeIntervalSince(last.at) < 2 * 60 else { return nil }
        return last
    }
    private(set) var lastProgressAt: Date?
    private(set) var lastHeartbeatAt: Date?
    /// When the orchestrator last named this miner's run (heartbeat or run-config response).
    /// Only a miner that is in a run gets these, so it is evidence of being in one.
    private(set) var lastRunNamedAt: Date?
    /// When the orchestrator last answered `EntityNotRegistered`.
    private(set) var lastNotRegisteredAt: Date?
    private(set) var lastPhase: MinerPhase = .training
    private(set) var lastStartAt: Date?
    private(set) var lastShutdownAt: Date?
    private(set) var lastFatal: (at: Date, reason: String)?
    private(set) var lastControlStopAt: Date?
    private(set) var outageEventTimes: [Date] = []

    // Evidence from the probes.
    private(set) var lastSnapshot: ProcessSnapshot?
    private var missingWorkerPolls = 0
    /// Times the miner reset its own state, used to spot a reset/re-register loop.
    private(set) var resetTimes: [Date] = []
    /// When this watchdog first saw the worker alive.
    ///
    /// Needed as a fallback baseline for the no-progress rule: the miner's log keeps only about
    /// 90 minutes of history and the tailer bootstraps from the tail of it, so after the
    /// watchdog itself restarts there may be no progress mark at all. Without this, a miner that
    /// was already idle before the watchdog started would never trip the rule — it would sit
    /// there forever with the log reading "last progress —".
    private(set) var firstSeenRunningAt: Date?

    // API evidence.
    private(set) var apiActivationCount: Int?
    private(set) var apiActivationsChangedAt: Date?
    private(set) var apiReachable = true
    /// The run's synchronisation schedule, from the public API.
    private(set) var lastSyncAt: Date?
    private(set) var nextSyncAt: Date?
    /// Set when the miner's whole run has fallen far behind the others.
    private(set) var runStalledForHours: Double?
    /// When the miner last registered into a run.
    private(set) var lastRegisteredAt: Date?

    // Our own actions.
    private(set) var restartTimes: [Date] = []
    private(set) var pausedUntil: Date?
    private(set) var userStopped = false
    /// A trigger already proposed and awaiting the user's countdown, so we don't propose twice.
    private(set) var pendingTrigger: RestartTrigger?
    /// A trigger already reported as suppressed, so the reason is logged once, not every poll.
    private var suppressedTrigger: RestartTrigger?

    /// Wall clock, injectable for tests.
    private let now: () -> Date
    /// Time the Mac last woke, supplied by PowerMonitor.
    var lastWakeAt: Date?

    /// `config` defaults to nil for the same reason as the coordinator's collaborators: with
    /// default main-actor isolation, a `WatchdogConfig()` default argument would be built in a
    /// nonisolated context.
    init(config: WatchdogConfig? = nil, now: @escaping () -> Date = Date.init) {
        self.config = config ?? WatchdogConfig()
        self.now = now
    }

    // MARK: Ingestion

    /// Folds a batch of log events into the engine's state.
    func ingest(_ logEvents: [LogEvent]) {
        for event in logEvents {
            lastLogEventAt = max(lastLogEventAt ?? .distantPast, event.timestamp)

            switch event.kind {
            case .submitActivation:
                // An activation is the only unambiguous proof the miner did training work, and
                // it only happens while training, so it also unsticks the phase: the miner logs
                // the move *into* weights_uploading but almost never the move back.
                lastPhase = .training
                noteProgress(at: event.timestamp)
                submittedActivationTimes.append(event.timestamp)
                submittedActivationTimes.removeAll {
                    event.timestamp.timeIntervalSince($0) > config.peerLossWindow * 2
                }

            case .trainingState(.trainingTick):
                // Deliberately NOT progress. A miner stuck in a reset/re-register loop emits a
                // tick as part of each registration, which kept the no-progress clock reset and
                // hid a miner that had done nothing for six hours.
                lastPhase = .training

            case .layerPhaseChange(let actual, _):
                lastPhase = actual
                noteProgress(at: event.timestamp)

            case .heartbeat:
                lastHeartbeatAt = event.timestamp

            case .chatter:
                break

            case .registered(let prefix):
                // Registering is not progress either: it is what a looping miner does over and
                // over. It still marks when the miner joined the run, for the sync rule.
                lastRegisteredAt = event.timestamp
                lastPhase = .training
                clearQueue()
                record("Registered in a run\(prefix.isEmpty ? "" : " as \(prefix)")", notable: true)

            case .minerStarting, .processSpawned:
                lastStartAt = event.timestamp
                clearQueue()
                // A new process has new connections; the old one's reports say nothing about it.
                peerReports.removeAll()
                droppedActivationTimes.removeAll()
                submittedActivationTimes.removeAll()
                lastShutdownAt = nil
                lastFatal = nil
                userStopped = false
                pendingTrigger = nil
                suppressedTrigger = nil
                missingWorkerPolls = 0
                firstSeenRunningAt = event.timestamp
                resetTimes.removeAll()
                record("Miner started", notable: true)

            case .startRequested:
                lastStartAt = event.timestamp

            case .trainingState(.resetting), .resettingState:
                // Self-recovery after being kicked. Normal once; a loop of them is a failure,
                // so they are counted rather than treated as progress.
                resetTimes.append(event.timestamp)
                resetTimes.removeAll { event.timestamp.timeIntervalSince($0) > config.resetLoopWindow }
                record("Miner reset its state", notable: false)

            case .trainingState:
                break

            case .criticalError(let reason):
                lastFatal = (event.timestamp, reason)
                record("Fatal error: \(reason)", notable: true)

            case .shutdownComplete, .processExited:
                lastShutdownAt = event.timestamp
                clearQueue()
                record("Miner shut down", notable: true)

            case .controlStopRequested:
                lastControlStopAt = event.timestamp
                userStopped = true
                record("Stop requested in the IOTA app", notable: true)

            case .protocolReconnectFailed:
                record("Lost the connection to the miner process", notable: false)

            case .orchestratorUnreachable:
                outageEventTimes.append(event.timestamp)

            case .runNamed(let runID):
                lastRunNamedAt = event.timestamp
                // Every heartbeat carries this, so it is recorded only when it changes.
                // A change is genuinely worth knowing: it is the only signal that the
                // orchestrator has moved this miner to a different run.
                if namedRunID != runID {
                    record("Orchestrator assigned run \(runID)", notable: true)
                    namedRunID = runID
                }

            case .joiningWaitlist:
                joinedWaitlistAt = event.timestamp

            case .registrationQueue(let status, let position):
                // Positions move every poll, often by hundreds, so only status changes are
                // worth a line in the history.
                // By stage rather than by status: past the queue the orchestrator flips between
                // `confirmed` and `processing` every minute or so (Mac Mini, 2026-10-18).
                if queueStatus.map(Self.queueStage) != Self.queueStage(status) {
                    switch Self.queueStage(status) {
                    case "queued":
                        record("Joined the registration queue" + (position.map { " at #\($0)" } ?? ""),
                               notable: true)
                    case "expired":
                        record("Queue place expired; the miner joins again", notable: true)
                    default:
                        record("Through the queue; joining a run (\(status))", notable: true)
                    }
                }
                queueStatus = status
                reportedQueuePosition = position
                queueStatusAt = event.timestamp
                // In the queue means in no run: forget the last one so the menu does not
                // claim the miner is queueing for a run it has already left.
                namedRunID = nil

            case .notRegistered:
                namedRunID = nil
                lastNotRegisteredAt = event.timestamp

            case .peerStatus(let reachable, let total):
                let report = PeerReport(at: event.timestamp, reachable: reachable, total: total)
                peerReports.append(report)
                peerReports.removeAll { event.timestamp.timeIntervalSince($0.at) > config.peerLossWindow * 2 }
                // A healthy report after a peer-loss restart means the restart worked.
                if peerLossRestartAt != nil, total > 0, report.fraction > config.peerLossMaxFraction {
                    peerLossRestartAt = nil
                    record("Back in contact with the other miners (\(reachable)/\(total))", notable: true)
                }

            case .forwardActivationDropped:
                droppedActivationTimes.append(event.timestamp)
                droppedActivationTimes.removeAll {
                    event.timestamp.timeIntervalSince($0) > config.peerLossWindow * 2
                }

            case .queueState(let detail):
                // The worker advertises this capability but has never emitted one here, so the
                // payload is logged verbatim the first time it appears rather than guessed at.
                if lastQueueState != detail {
                    lastQueueState = detail
                    record("Queue state: \(detail.isEmpty ? "(no payload)" : detail)", notable: true)
                }
            }
        }

        // Keep only the outage events inside the window.
        let cutoff = now().addingTimeInterval(-config.outageWindow)
        outageEventTimes.removeAll { $0 < cutoff }
    }

    /// The run the orchestrator last named for this miner. Known from the log even while the
    /// miner is still queueing, i.e. before it appears in the API's miner list.
    private(set) var namedRunID: String?
    /// When the miner last asked to join the registration waitlist.
    private(set) var joinedWaitlistAt: Date?
    /// The raw payload of the most recent `register.queue_state` message, if one has ever come.
    private(set) var lastQueueState: String?

    /// A queue position parsed out of the worker's queue-state payload.
    ///
    /// Returns nil unless the payload actually contains a position, which it never has on any
    /// log seen so far. Showing an invented number would be worse than showing nothing.
    var queuePosition: Int? {
        if isQueued, let reportedQueuePosition { return reportedQueuePosition }
        guard let payload = lastQueueState else { return nil }
        for key in ["position", "place", "rank", "index"] {
            guard let range = payload.range(of: key) else { continue }
            let digits = payload[range.upperBound...]
                .drop { !$0.isNumber }
                .prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// Records that the worker wrote something, whether or not it parsed into an event.
    func noteWorkerOutput(at date: Date) {
        lastWorkerOutputAt = max(lastWorkerOutputAt ?? .distantPast, date)
    }

    /// The most recent sign of life in the miner's log: a recognised event, or any worker line.
    var lastLogActivityAt: Date? {
        [lastLogEventAt, lastWorkerOutputAt].compactMap { $0 }.max()
    }

    /// True while the orchestrator says the miner is queued, and said so recently. A queue that
    /// has stopped reporting is no longer an excuse, so the ordinary rules apply again.
    ///
    /// Every status except `expired` counts. 1.5 knew only `queued`; on 2026-10-18 the
    /// orchestrator moved the Mac Mini on to `confirming`, `confirmed` and `processing`, and
    /// the watchdog took that as the end of the queue and reported "Training" for a miner in
    /// no run. A status not seen before is treated as still waiting, which is the safe side.
    var isQueued: Bool {
        guard let status = queueStatus, status != "expired", let at = queueStatusAt else { return false }
        return now().timeIntervalSince(at) < 10 * 60
    }

    /// True when at least one activation was submitted after `date`.
    func hasSubmitted(since date: Date) -> Bool {
        submittedActivationTimes.contains { $0 > date }
    }

    /// The state for a miner that is demonstrably working.
    private var workingState: WatchdogState {
        lastPhase == .training ? .training : .otherPhase(lastPhase)
    }

    /// `queued`, `expired`, or `joining` for everything after the queue proper.
    static func queueStage(_ status: String) -> String {
        switch status {
        case "queued", "expired": return status
        default: return "joining"
        }
    }

    /// Something in the last ten minutes that only a miner in a run, or training, produces:
    /// a heartbeat, the orchestrator naming its run, or a submitted activation. A miner in no
    /// run sends none of them (Mac Mini, 2026-10-18: zero for 40 minutes; the MacBook, in a
    /// run, about four heartbeats a minute).
    var hasRecentTrainingEvidence: Bool {
        let latest = [lastHeartbeatAt, lastRunNamedAt, submittedActivationTimes.last].compactMap { $0 }.max()
        guard let latest else { return false }
        return now().timeIntervalSince(latest) < 10 * 60
    }

    /// The peer-loss evidence, if the last `peerLossWindow` meets every condition: reports all
    /// the way through it, every one of them at or below `peerLossMaxFraction`, enough of them,
    /// the latest still current, and the time wasted: work dropped, or no work at all. Nil
    /// otherwise.
    func peerLossEvidence(at date: Date) -> (reachable: Int, total: Int, dropped: Int, submitted: Int)? {
        let start = date.addingTimeInterval(-config.peerLossWindow)
        // Reports must reach back to the start of the window, not merely exist inside it,
        // so a watchdog that has only just started cannot conclude anything from a few minutes.
        guard let first = peerReports.first, first.at <= start.addingTimeInterval(60) else { return nil }
        let inWindow = peerReports.filter { $0.at >= start }
        guard inWindow.count >= config.peerLossMinReports,
              let last = inWindow.last, date.timeIntervalSince(last.at) < 2 * 60,
              inWindow.allSatisfy({ $0.total > 0 && $0.fraction <= config.peerLossMaxFraction })
        else { return nil }
        let dropped = droppedActivationTimes.filter { $0 >= start }.count
        let submitted = submittedActivationTimes.filter { $0 >= start }.count
        // A miner still handing work on, however few peers it sees, is not wasting its time.
        guard dropped >= config.peerLossMinDropped || submitted == 0 else { return nil }
        return (last.reachable, last.total, dropped, submitted)
    }

    private func clearQueue() {
        queueStatus = nil
        reportedQueuePosition = nil
        queueStatusAt = nil
    }

    /// Records the latest local process observation.
    func ingest(_ snapshot: ProcessSnapshot) {
        lastSnapshot = snapshot
        if snapshot.workerRunning {
            missingWorkerPolls = 0
            if firstSeenRunningAt == nil { firstSeenRunningAt = now() }
        } else {
            missingWorkerPolls += 1
            firstSeenRunningAt = nil
        }
    }

    /// Records the latest API observation for the local miner.
    func ingestAPI(activationCount: Int?, reachable: Bool,
                   lastSyncAt: Date? = nil, nextSyncAt: Date? = nil,
                   runStalledForHours: Double? = nil) {
        apiReachable = reachable
        self.runStalledForHours = runStalledForHours
        if let lastSyncAt { self.lastSyncAt = lastSyncAt }
        if let nextSyncAt { self.nextSyncAt = nextSyncAt }
        guard let activationCount else { return }
        if activationCount != apiActivationCount {
            apiActivationCount = activationCount
            apiActivationsChangedAt = now()
        } else if apiActivationsChangedAt == nil {
            apiActivationsChangedAt = now()
        }
    }

    private func noteProgress(at date: Date) {
        lastProgressAt = max(lastProgressAt ?? .distantPast, date)
    }

    // MARK: Evaluation

    /// Works out the current state and what, if anything, to do about it.
    @discardableResult
    func evaluate() -> WatchdogDecision {
        let currentTime = now()

        // Paused by the user.
        if let pausedUntil, currentTime < pausedUntil {
            state = .paused(until: pausedUntil)
            return .doNothing
        }
        if pausedUntil != nil { pausedUntil = nil }

        guard let snapshot = lastSnapshot else {
            state = .unknown
            return .doNothing
        }

        // The host app itself is gone: nothing else can be judged, just start it.
        if !snapshot.hostAppRunning {
            state = .stopped
            guard config.autoRestartEnabled, !userStopped, canRestart(at: currentTime) else {
                return .doNothing
            }
            return .launchHostApp
        }

        // A deliberate stop wins over every automatic rule, including while the worker process
        // is still winding down after the shutdown it was asked for.
        if userStopped, !snapshot.workerRunning || lastShutdownAt != nil {
            state = .stoppedByUser
            return .doNothing
        }

        // --- Rule 1: the miner is no longer training. The most important rule. ---
        //
        // `🛑 Miner shutdown complete` means training has ended, whatever the process table says,
        // and nothing will restart it: the IOTA app never does. On the Mac Mini on 2026-10-08 the
        // miner sat idle for ten minutes after it until someone intervened.
        //
        // Timing, from that same log:
        //   10:29:30  ❌ Critical error in run_miner (NaN pseudo gradients)
        //   10:32:11  🛑 Miner shutdown complete      — 2 min 41 s of cleanup in between
        // So a fatal error starts a wait for the shutdown line (up to `fatalCleanupWait`), and the
        // shutdown line starts a short wait for the process to exit (`shutdownExitWait`). After
        // either, restart regardless of whether a worker process is still listed; the restarter
        // reaps whatever is left. The old rule waited for the process to vanish, with no limit.
        //
        // Checked before the grace periods, the stalled-run rule and the sync wait on purpose:
        // those describe a miner that is still training. This one is not.
        //
        // Both signals are cleared by the next `🚀 Starting miner`, so a fatal error or shutdown
        // the miner recovers from by itself never reaches here, and an old one is never stale.
        if lastShutdownAt != nil || lastFatal != nil {
            let deadline = lastShutdownAt.map { $0.addingTimeInterval(config.shutdownExitWait) }
                ?? lastFatal!.at.addingTimeInterval(config.fatalCleanupWait)
            if snapshot.workerRunning, currentTime < deadline {
                state = .settling(reason: "miner shutting down")
                return .doNothing
            }
            state = .stopped
            let trigger: RestartTrigger = lastFatal.map { .fatalError(reason: $0.reason) } ?? .shutdown
            return propose(trigger, at: currentTime)
        }

        // --- Grace periods: never judge a settling miner. ---
        //
        // The grace blocks every restart rule below, but it must not hide a miner that is
        // visibly working: on 2026-10-18 the MacBook read "Settling" for the full ten minutes
        // while submitting activations from the sixth.
        if let lastStartAt, currentTime.timeIntervalSince(lastStartAt) < config.startupGrace {
            state = hasSubmitted(since: lastStartAt) ? workingState : .settling(reason: "just started")
            return .doNothing
        }
        if let lastWakeAt, currentTime.timeIntervalSince(lastWakeAt) < config.wakeGrace {
            state = hasSubmitted(since: lastWakeAt) ? workingState : .settling(reason: "Mac just woke")
            return .doNothing
        }

        // --- Rule 2: the worker is gone while the app is running. ---
        if !snapshot.workerRunning {
            if missingWorkerPolls >= config.stoppedConfirmations {
                state = .stopped
                return propose(.stopped, at: currentTime)
            }
            state = .settling(reason: "worker not seen once")
            return .doNothing
        }

        // From here the worker is alive.

        // --- Network outage guard: applies to the freeze and no-progress rules only. ---
        let outageActive = outageEventTimes.count >= config.outageEventThreshold || !apiReachable

        // --- The whole run is dead, not this miner. ---
        //
        // Checked before every restart rule, because none of them can help. The orchestrator
        // reassigns a restarted miner to the same run, so restarting only costs re-registration
        // time, repeatedly. Observed 2026-09-06: a run 63.9 hours behind while nine others had
        // synced within the hour. The fix is a different run, which is not ours to arrange.
        if config.holdForRunStateEnabled, let stalledHours = runStalledForHours {
            state = .runStalled(hours: stalledHours)
            return suppressedRestartForStalledRun(at: currentTime)
        }

        // --- Waiting in the registration queue. ---
        //
        // A queued miner is healthy and has nothing to do but poll its place. On 2026-10-11 the
        // watchdog restarted one that had been queued for two hours, calling it frozen, because
        // none of its queue lines were ones the parser recognised. Placed before every rule that
        // judges a live worker. If the queue stops reporting, `isQueued` lapses after ten minutes
        // and those rules apply again.
        if isQueued {
            state = queueStatus == "queued"
                ? .queued(position: reportedQueuePosition)
                : .joiningRun(status: queueStatus ?? "")
            return .doNothing
        }

        // --- Rule 3: alive but writing nothing. ---
        //
        // "Nothing" means no line at all from the worker, not merely no line the parser knows.
        if let lastActivity = lastLogActivityAt {
            let logAge = currentTime.timeIntervalSince(lastActivity)
            if logAge >= config.frozenThreshold {
                if outageActive {
                    state = .networkOutage
                    return .doNothing
                }
                state = .frozen
                return propose(.frozen(logAge: logAge), at: currentTime)
            }
        }

        // --- Rule 4: cut off from the other miners. ---
        //
        // Added 2026-10-16. A miner process ran for a day, then lost contact with every peer
        // while staying alive, busy and heartbeating: 0/36 reachable for hours, every finished
        // activation dropped, credited a quarter of its twin's work. Cables, adapters, switches
        // and Wi-Fi were all ruled out; the Mac Mini on the same router stayed healthy. Restarting
        // the miner fixed it at once (16/28 within a minute, 0 dropped over the next 80).
        if let lost = peerLossEvidence(at: currentTime) {
            if outageActive {
                state = .networkOutage
                return .doNothing
            }
            state = .cutOffFromPeers(reachable: lost.reachable, total: lost.total)
            let trigger = RestartTrigger.peersLost(minutes: Int(config.peerLossWindow / 60))
            // One restart is the cure for a stuck process. If it did not reconnect, the cause
            // is outside this Mac, and restarting again would only repeat 2–4 October.
            if let tried = peerLossRestartAt,
               currentTime.timeIntervalSince(tried) < config.peerLossRetryAfter {
                return suppress(trigger, "a restart already failed to reconnect it, so the cause "
                                + "looks to be outside this Mac (the network or the run)")
            }
            return propose(trigger, at: currentTime)
        }


        // --- Waiting for the run's next full synchronisation. ---
        //
        // A miner that registered mid-epoch is idle by design until the next sync. Restarting
        // makes it worse: it re-registers, misses that sync too, and waits for the one after.
        if config.holdForRunStateEnabled, isWaitingForSync, let next = nextSyncAt {
            state = .waitingForSync(until: next)
            return .doNothing
        }

        // --- A sustained reset/re-register loop. ---
        //
        // Deliberately conservative, and deliberately placed *after* the sync excuse. Looping is
        // normal while joining a run, so this needs three things at once: enough resets, a loop
        // that has lasted longer than any join period observed, and the public API agreeing that
        // the miner is being credited with nothing. A wrong restart here slows the whole run,
        // which is far worse than noticing late.
        let resets = recentResetCount
        if config.resetLoopRuleEnabled,
           resets >= config.resetLoopThreshold,
           resetLoopDuration >= config.resetLoopMinimumDuration,
           apiActivationsAreStalled(at: currentTime, for: config.resetLoopMinimumDuration) {
            if outageActive {
                state = .networkOutage
                return .doNothing
            }
            state = .notProgressing
            return propose(.resetLoop(count: resets,
                                      minutes: Int(resetLoopDuration / 60)),
                           at: currentTime)
        }

        // --- Rule 4 (optional): alive and writing, but no training progress. ---
        if config.noProgressRuleEnabled, let baseline = progressBaseline {
            let progressAge = currentTime.timeIntervalSince(baseline)
            let apiStalled = apiActivationsChangedAt.map {
                currentTime.timeIntervalSince($0) >= config.noProgressThreshold
            } ?? false

            if progressAge >= config.noProgressThreshold, apiStalled {
                if outageActive {
                    state = .networkOutage
                    return .doNothing
                }
                state = .notProgressing
                return propose(.noProgress(since: progressAge), at: currentTime)
            }
        }

        // Healthy, as far as the enabled rules can tell.
        pendingTrigger = nil
        suppressedTrigger = nil
        resetTimes.removeAll()
        // With the hold switched off these no longer block anything, but a dead run or a queued
        // miner is still worth saying, rather than claiming "Training".
        if let stalledHours = runStalledForHours {
            state = .runStalled(hours: stalledHours)
        } else if isWaitingForSync, let next = nextSyncAt {
            state = .waitingForSync(until: next)
        } else {
            // "Training" must be earned. The last phase the miner reported can be hours old,
            // and on 2026-10-18 it read "Training" for a miner that had been out of its run
            // since 05:40.
            if lastPhase == .training, !hasRecentTrainingEvidence {
                let notInRun = lastNotRegisteredAt.map { currentTime.timeIntervalSince($0) < 10 * 60 } ?? false
                state = notInRun ? .notInRun : .idle
            } else {
                state = lastPhase == .training ? .training : .otherPhase(lastPhase)
            }
        }
        return .doNothing
    }

    // MARK: Restart bookkeeping

    /// True when the miner registered after the run's last full synchronisation, so it is queued
    /// for the next one and can do nothing until then.
    ///
    /// Confirmed in the Macrocosmos docs: a miner that registers waits for the next full
    /// synchronisation, where it aligns weights and optimiser state, before it processes any
    /// activations. Observed here: registered 23:58, last sync 22:37, next sync 00:42.
    var isWaitingForSync: Bool {
        guard let joined = joinedRunAt, let lastSync = lastSyncAt else { return false }
        guard joined > lastSync else { return false }
        // A miner that is already submitting activations is not waiting for anything. The sync
        // estimate is only an estimate: on 2026-10-18 the MacBook trained from 10:43 while the
        // watchdog still read "Waiting for network sync (~10:51)" at 10:47.
        guard !hasSubmitted(since: joined) else { return false }
        guard let next = nextSyncAt else { return false }
        // Bounded on purpose. The estimate slides forward on every poll, so "wait until the
        // next estimate" is a wait that never ends. Once the miner has been queued for longer
        // than the cap, the sync is not coming and the ordinary rules apply again.
        guard now().timeIntervalSince(joined) < config.syncWaitCap else { return false }
        return now() < next.addingTimeInterval(syncGrace)
    }

    /// Resets seen inside the loop window.
    var recentResetCount: Int {
        resetTimes.filter { now().timeIntervalSince($0) <= config.resetLoopWindow }.count
    }

    /// How long the current run of resets has been going, measured from the oldest one still
    /// inside the window. A short burst is a miner joining; hours of it is a miner stuck.
    var resetLoopDuration: TimeInterval {
        let inWindow = resetTimes.filter { now().timeIntervalSince($0) <= config.resetLoopWindow }
        guard let oldest = inWindow.min() else { return 0 }
        return now().timeIntervalSince(oldest)
    }

    /// When this miner joined the current epoch.
    ///
    /// Prefers the registration line, but falls back to when the worker was started. The miner's
    /// own log keeps only about 90 minutes and the tailer reads from its tail, so the
    /// registration line is often already gone; the start is recorded in main.log, which is
    /// small enough to be read in full and therefore survives.
    var joinedRunAt: Date? {
        lastRegisteredAt ?? lastStartAt
    }

    /// Extra time allowed after the estimated sync, since the estimate moves around.
    private let syncGrace: TimeInterval = 15 * 60

    /// The point the no-progress rule measures from: the last real sign of progress, or failing
    /// that the moment this watchdog first saw the worker running.
    var progressBaseline: Date? {
        lastProgressAt ?? firstSeenRunningAt
    }

    /// When the no-progress rule will fire if nothing changes, so the UI can say what is going
    /// to happen instead of appearing to do nothing.
    var noProgressDeadline: Date? {
        guard config.noProgressRuleEnabled else { return nil }
        return progressBaseline?.addingTimeInterval(config.noProgressThreshold)
    }

    /// How long the miner has gone without any sign of training progress.
    var progressAge: TimeInterval? {
        progressBaseline.map { now().timeIntervalSince($0) }
    }

    /// True when the public API has credited no new activations for at least `duration`.
    /// Returns false when we have never had an API reading, so a rule that depends on it
    /// cannot fire on missing evidence.
    func apiActivationsAreStalled(at date: Date, for duration: TimeInterval) -> Bool {
        guard let changed = apiActivationsChangedAt else { return false }
        return date.timeIntervalSince(changed) >= duration
    }

    /// Whether the restart budget allows another attempt.
    func canRestart(at date: Date? = nil) -> Bool {
        let currentTime = date ?? now()
        let recent = restartTimes.filter { currentTime.timeIntervalSince($0) < 3600 }
        if recent.count >= config.maxRestartsPerHour { return false }
        if let last = restartTimes.last,
           currentTime.timeIntervalSince(last) < config.minRestartSpacing {
            return false
        }
        return true
    }

    /// Emits a restart proposal, unless auto-restart is off, the budget is spent, or the same
    /// trigger is already awaiting the user's countdown.
    private func propose(_ trigger: RestartTrigger, at date: Date) -> WatchdogDecision {
        guard config.autoRestartEnabled else {
            return suppress(trigger, "automatic restart is switched off")
        }
        guard !userStopped else {
            return suppress(trigger, "you stopped the miner, or cancelled a restart")
        }
        guard pendingTrigger != trigger else { return .doNothing }

        guard canRestart(at: date) else {
            let recent = restartTimes.filter { date.timeIntervalSince($0) < 3600 }.count
            let reason = recent >= config.maxRestartsPerHour
                ? "restarted \(recent) times in the last hour"
                : "waiting before another restart"
            state = .needsAttention(reason: reason)
            return suppress(trigger, reason)
        }

        suppressedTrigger = nil
        pendingTrigger = trigger
        record("Proposing restart: \(trigger.title)", notable: true)
        return .proposeRestart(trigger)
    }

    /// Says once, rather than every poll, that the run itself is the problem.
    private func suppressedRestartForStalledRun(at date: Date) -> WatchdogDecision {
        let trigger = RestartTrigger.noProgress(since: date.timeIntervalSince(progressBaseline ?? date))
        return suppress(trigger, "the whole run has stopped syncing — restarting rejoins the "
                        + "same run, so it cannot help")
    }

    /// Reports a blocked restart once per trigger, so the log explains the inaction.
    private func suppress(_ trigger: RestartTrigger, _ reason: String) -> WatchdogDecision {
        guard suppressedTrigger != trigger else { return .doNothing }
        suppressedTrigger = trigger
        record("Would restart (\(trigger.title)) but \(reason)", notable: true)
        return .suppressedRestart(trigger, reason: reason)
    }

    /// Called when a restart actually began.
    func recordRestartStarted(at date: Date? = nil) {
        let currentTime = date ?? now()
        if case .peersLost = pendingTrigger { peerLossRestartAt = currentTime }
        restartTimes.append(currentTime)
        restartTimes.removeAll { currentTime.timeIntervalSince($0) > 3600 }
        pendingTrigger = nil
        lastStartAt = currentTime
        lastShutdownAt = nil
        lastFatal = nil
        missingWorkerPolls = 0
        record("Restarting the miner", notable: true)
    }

    /// Called when the user cancels the countdown.
    func recordRestartCancelled() {
        pendingTrigger = nil
        userStopped = true
        state = .stoppedByUser
        record("Restart cancelled — automatic restarts are off until the miner runs again",
               notable: true)
    }

    /// Re-arms automatic restarts after a cancellation or a deliberate stop.
    func resumeAutomaticRestarts() {
        userStopped = false
        pendingTrigger = nil
        record("Automatic restarts re-enabled", notable: true)
    }

    /// Pauses all watching for a while.
    func pause(for duration: TimeInterval) {
        pausedUntil = now().addingTimeInterval(duration)
        pendingTrigger = nil
        record("Paused for \(Int(duration / 60)) minutes", notable: true)
    }

    // MARK: History

    private func record(_ text: String, notable: Bool) {
        events.append(WatchdogEvent(at: now(), text: text, isNotable: notable))
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }
}
