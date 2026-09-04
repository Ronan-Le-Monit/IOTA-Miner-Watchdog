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
    /// Restarts allowed in any rolling hour.
    var maxRestartsPerHour = 3
    /// Never restart twice within this window.
    var minRestartSpacing: TimeInterval = 10 * 60
    /// Seconds the user gets to cancel an automatic restart.
    var confirmationCountdown: TimeInterval = 60
    /// Orchestrator-unreachable events within this window that mean "the network is down".
    var outageWindow: TimeInterval = 10 * 60
    var outageEventThreshold = 3
    /// Hotkey prefix of the miner on this Mac.
    var localPrefix = "5DXDN2UR"
    /// Master switch for automatic restarts.
    var autoRestartEnabled = true
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
    /// Restart budget exhausted; needs a human.
    case needsAttention(reason: String)
    /// Watchdog paused by the user.
    case paused(until: Date)
    /// Not enough information yet (just launched).
    case unknown

    /// Whether this state should read as a problem in the UI.
    var isProblem: Bool {
        switch self {
        case .stopped, .frozen, .notProgressing, .needsAttention: return true
        case .training, .otherPhase, .settling, .stoppedByUser, .networkOutage, .paused, .unknown:
            return false
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

    var title: String {
        switch self {
        case .fatalError: return "IOTA miner crashed"
        case .shutdown: return "IOTA miner stopped"
        case .stopped: return "IOTA miner is not running"
        case .frozen: return "IOTA miner appears frozen"
        case .noProgress: return "IOTA miner is not making progress"
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
    private(set) var lastProgressAt: Date?
    private(set) var lastHeartbeatAt: Date?
    private(set) var lastPhase: MinerPhase = .training
    private(set) var lastStartAt: Date?
    private(set) var lastShutdownAt: Date?
    private(set) var lastFatal: (at: Date, reason: String)?
    private(set) var lastControlStopAt: Date?
    private(set) var outageEventTimes: [Date] = []

    // Evidence from the probes.
    private(set) var lastSnapshot: ProcessSnapshot?
    private var missingWorkerPolls = 0

    // API evidence.
    private(set) var apiActivationCount: Int?
    private(set) var apiActivationsChangedAt: Date?
    private(set) var apiReachable = true

    // Our own actions.
    private(set) var restartTimes: [Date] = []
    private(set) var pausedUntil: Date?
    private(set) var userStopped = false
    /// A trigger already proposed and awaiting the user's countdown, so we don't propose twice.
    private(set) var pendingTrigger: RestartTrigger?

    /// Wall clock, injectable for tests.
    private let now: () -> Date
    /// Time the Mac last woke, supplied by PowerMonitor.
    var lastWakeAt: Date?

    init(config: WatchdogConfig = WatchdogConfig(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
    }

    // MARK: Ingestion

    /// Folds a batch of log events into the engine's state.
    func ingest(_ logEvents: [LogEvent]) {
        for event in logEvents {
            lastLogEventAt = max(lastLogEventAt ?? .distantPast, event.timestamp)

            switch event.kind {
            case .submitActivation, .trainingState(.trainingTick):
                // Activations and training ticks only happen while training, and the miner logs
                // the move *into* weights_uploading but almost never the move back (17 vs 2 over
                // three days). Without this the phase would stick at "uploading" forever.
                lastPhase = .training
                noteProgress(at: event.timestamp)

            case .layerPhaseChange(let actual, _):
                lastPhase = actual
                noteProgress(at: event.timestamp)

            case .heartbeat:
                lastHeartbeatAt = event.timestamp

            case .chatter:
                break

            case .registered(let prefix):
                noteProgress(at: event.timestamp)
                lastPhase = .training
                record("Registered in a run\(prefix.isEmpty ? "" : " as \(prefix)")", notable: true)

            case .minerStarting, .processSpawned:
                lastStartAt = event.timestamp
                lastShutdownAt = nil
                lastFatal = nil
                userStopped = false
                pendingTrigger = nil
                missingWorkerPolls = 0
                record("Miner started", notable: true)

            case .startRequested:
                lastStartAt = event.timestamp

            case .trainingState(.resetting), .resettingState:
                // Self-recovery after being kicked. Counts as activity, not as a failure.
                noteProgress(at: event.timestamp)
                record("Miner reset its state (normal self-recovery)", notable: false)

            case .trainingState:
                break

            case .criticalError(let reason):
                lastFatal = (event.timestamp, reason)
                record("Fatal error: \(reason)", notable: true)

            case .shutdownComplete, .processExited:
                lastShutdownAt = event.timestamp
                record("Miner shut down", notable: true)

            case .controlStopRequested:
                lastControlStopAt = event.timestamp
                userStopped = true
                record("Stop requested in the IOTA app", notable: true)

            case .protocolReconnectFailed:
                record("Lost the connection to the miner process", notable: false)

            case .orchestratorUnreachable:
                outageEventTimes.append(event.timestamp)
            }
        }

        // Keep only the outage events inside the window.
        let cutoff = now().addingTimeInterval(-config.outageWindow)
        outageEventTimes.removeAll { $0 < cutoff }
    }

    /// Records the latest local process observation.
    func ingest(_ snapshot: ProcessSnapshot) {
        lastSnapshot = snapshot
        if snapshot.workerRunning {
            missingWorkerPolls = 0
        } else {
            missingWorkerPolls += 1
        }
    }

    /// Records the latest API observation for the local miner.
    func ingestAPI(activationCount: Int?, reachable: Bool) {
        apiReachable = reachable
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

        // A deliberate stop wins over every automatic rule.
        if userStopped, !snapshot.workerRunning {
            state = .stoppedByUser
            return .doNothing
        }

        // --- Rule 1: fatal error or clean shutdown, the fast path. ---
        let fatalIsRecent = lastFatal.map { currentTime.timeIntervalSince($0.at) < 5 * 60 } ?? false
        let shutdownSeen = lastShutdownAt != nil && !snapshot.workerRunning

        if (fatalIsRecent || shutdownSeen), !snapshot.workerRunning {
            state = .stopped
            let trigger: RestartTrigger = lastFatal.map { .fatalError(reason: $0.reason) }
                ?? .shutdown
            return propose(trigger, at: currentTime)
        }

        // --- Grace periods: never judge a settling miner. ---
        if let lastStartAt, currentTime.timeIntervalSince(lastStartAt) < config.startupGrace {
            state = .settling(reason: "just started")
            return .doNothing
        }
        if let lastWakeAt, currentTime.timeIntervalSince(lastWakeAt) < config.wakeGrace {
            state = .settling(reason: "Mac just woke")
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

        // --- Rule 3: alive but writing nothing. ---
        if let lastLogEventAt {
            let logAge = currentTime.timeIntervalSince(lastLogEventAt)
            if logAge >= config.frozenThreshold {
                if outageActive {
                    state = .networkOutage
                    return .doNothing
                }
                state = .frozen
                return propose(.frozen(logAge: logAge), at: currentTime)
            }
        }

        // --- Rule 4: alive and writing, but no training progress. ---
        if let lastProgressAt {
            let progressAge = currentTime.timeIntervalSince(lastProgressAt)
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

        // Healthy.
        pendingTrigger = nil
        state = lastPhase == .training ? .training : .otherPhase(lastPhase)
        return .doNothing
    }

    // MARK: Restart bookkeeping

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
        guard config.autoRestartEnabled else { return .doNothing }
        guard pendingTrigger != trigger else { return .doNothing }

        guard canRestart(at: date) else {
            let recent = restartTimes.filter { date.timeIntervalSince($0) < 3600 }.count
            state = .needsAttention(
                reason: recent >= config.maxRestartsPerHour
                    ? "restarted \(recent) times in the last hour"
                    : "waiting before another restart")
            return .doNothing
        }

        pendingTrigger = trigger
        record("Proposing restart: \(trigger.title)", notable: true)
        return .proposeRestart(trigger)
    }

    /// Called when a restart actually began.
    func recordRestartStarted(at date: Date? = nil) {
        let currentTime = date ?? now()
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
