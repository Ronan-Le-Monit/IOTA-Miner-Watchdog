//
//  WatchdogCoordinator.swift
//  IOTA Watchdog
//
//  Owns the clock and the side effects: polls the log tailer and the probes, feeds the engine,
//  and carries out whatever the engine decides — including showing the 60-second confirmation
//  window before any automatic restart.
//

import Foundation
import Combine
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class WatchdogCoordinator: ObservableObject {

    /// The app's single coordinator. Held here rather than in a SwiftUI scene so the app delegate
    /// can start it at launch, before any menu is ever opened.
    static let shared = WatchdogCoordinator()

    // Collaborators.
    let engine: WatchdogEngine
    let settings: WatchdogSettings
    let power: PowerMonitor
    private let tailer: LogTailer
    private let probe: ProcessProbe
    private let apiProbe: APIProbe
    private var restarter: MinerRestarter
    private let logger: WatchdogLogger

    // Published state for the menu.
    @Published private(set) var lastAPI: APIObservation?
    @Published private(set) var lastPollAt: Date?
    @Published private(set) var isRestarting = false
    /// The restart awaiting the user's decision, if any.
    @Published private(set) var pendingConfirmation: PendingConfirmation?

    /// A restart proposal being counted down.
    struct PendingConfirmation: Equatable {
        let trigger: RestartTrigger
        let evidence: String
        var secondsRemaining: Int
    }

    private var pollTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var confirmationPanel: NSPanel?
    private var lastAPICheck: Date?
    /// The state most recently written to the log, so transitions are recorded once each.
    private var lastLoggedState: WatchdogState?
    private var cancellables: Set<AnyCancellable> = []

    /// How often the API is consulted. The logs are the fast signal; this is the second opinion.
    private let apiInterval: TimeInterval = 5 * 60

    /// Collaborators default to nil rather than to freshly built values.
    ///
    /// The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so these types are
    /// main-actor isolated, while a default parameter value is evaluated at the call site in a
    /// nonisolated context. Building them here, inside the isolated initialiser, is both correct
    /// and warning-free.
    init(settings: WatchdogSettings? = nil,
         tailer: LogTailer? = nil,
         probe: ProcessProbe? = nil,
         apiProbe: APIProbe? = nil,
         restarter: MinerRestarter? = nil,
         logger: WatchdogLogger? = nil) {
        let settings = settings ?? WatchdogSettings()
        self.settings = settings
        self.tailer = tailer ?? LogTailer()
        self.probe = probe ?? ProcessProbe()
        self.apiProbe = apiProbe ?? APIProbe()
        self.restarter = restarter ?? MinerRestarter()
        self.logger = logger ?? .shared
        self.power = PowerMonitor()
        self.engine = WatchdogEngine(config: settings.engineConfig)

        // Mirror settings changes into the engine promptly.
        //
        // These are delivered asynchronously on purpose. `@Published` fires its publisher from
        // `willSet`, so a sink that re-reads the property sees the value from *before* the
        // change. That bug left the engine with auto-restart off after the user switched it on,
        // and the miner sat stopped without a restart. `poll()` also re-syncs every cycle, so
        // the engine can never drift from the settings even if a notification is missed.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.syncConfig()
                self.power.setKeepAwake(self.settings.keepAwakeEnabled)
            }
            .store(in: &cancellables)
    }

    private func syncConfig() {
        engine.config = settings.engineConfig
    }

    // MARK: Lifecycle

    /// Starts polling. Safe to call once from the app's launch.
    func start() {
        guard pollTask == nil else { return }
        // The version goes in the first line so a log always says which build produced it.
        // Two Macs running different builds looked like one build behaving inconsistently.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        logger.log("Watchdog \(version) (\(build)) started"
            + " — auto-restart \(settings.autoRestartEnabled ? "on" : "off")"
            + ", keep-awake \(settings.keepAwakeEnabled ? "on" : "off")"
            + ", miner \(settings.localPrefix ?? "NOT IDENTIFIED")"
            + ", frozen after \(settings.frozenMinutes)m"
            + ", no-progress after \(settings.noProgressMinutes)m"
            + ", prefs domain \(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "?")?.count ?? -1) keys"
            + ", miner log dir \(FileManager.default.fileExists(atPath: tailer.directory.path) ? "readable" : "MISSING")")
        requestNotificationPermission()
        power.setKeepAwake(settings.keepAwakeEnabled)

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval = self?.engine.config.pollInterval ?? 30
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        power.setKeepAwake(false)
    }

    // MARK: One poll

    func poll() async {
        // 0. The engine's thresholds always come from the current settings.
        syncConfig()

        // 1. Logs.
        let events = tailer.poll()
        if !events.isEmpty { engine.ingest(events) }
        if let lastLine = tailer.lastWorkerLineAt { engine.noteWorkerOutput(at: lastLine) }

        // 2. Local processes.
        let snapshot = await probe.snapshot()
        engine.ingest(snapshot)

        // 3. The API, occasionally.
        let now = Date()
        // Only ask the API about a miner we can actually name. An empty prefix matches the
        // first miner in the list, which would quietly report a stranger's numbers.
        if let prefix = settings.localPrefix,
           lastAPICheck == nil || now.timeIntervalSince(lastAPICheck!) >= apiInterval {
            lastAPICheck = now
            // The engine knows, from the log, which run the orchestrator named — including
            // while the miner is still queueing and so absent from the API's miner lists.
            let observation = await apiProbe.observe(prefix: prefix, queueingFor: engine.namedRunID)
            lastAPI = observation
            engine.ingestAPI(activationCount: observation.activationCount,
                             reachable: observation.reachable,
                             lastSyncAt: observation.lastSyncAt,
                             nextSyncAt: observation.nextSyncAt,
                             runStalledForHours: observation.runAppearsStalled
                                ? (observation.runSyncAge ?? 0) / 3600
                                : nil)
        }

        // 4. Wake information.
        engine.lastWakeAt = power.lastWakeAt

        // 5. Keep-awake follows whether the miner is actually running.
        if settings.keepAwakeEnabled {
            power.setKeepAwake(snapshot.workerRunning)
        }

        lastPollAt = now

        // 6. Decide.
        guard !isRestarting, pendingConfirmation == nil else { return }
        let decision = engine.evaluate()

        // Record every state transition with the evidence behind it, so the log explains itself.
        if engine.state.logKey != lastLoggedState?.logKey {
            lastLoggedState = engine.state
            logger.log("State: \(engine.state.label)"
                + " | worker \(workerText)"
                + " | log age \(formatAge(logAge))"
                + " | last progress \(formatAge(engine.lastProgressAt.map { now.timeIntervalSince($0) }))"
                + (lastAPI?.activationCount.map { " | API activations \($0)" } ?? "")
                + {
                    guard settings.autoRestartEnabled,
                          let deadline = engine.noProgressDeadline,
                          let age = engine.progressAge, age > 5 * 60,
                          deadline > now else { return "" }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    return " | will restart at \(formatter.string(from: deadline)) if still idle"
                }())
        }

        switch decision {
        case .doNothing:
            break
        case .launchHostApp:
            logger.log("The IOTA app is not running — launching it")
            await performLaunch()
        case .proposeRestart(let trigger):
            beginConfirmation(for: trigger)
        case .suppressedRestart(let trigger, let reason):
            logger.log("NOT restarting — \(reason). Trigger: \(trigger.title). \(trigger.detail)")
            notify(title: "IOTA miner needs attention", body: "\(trigger.title). Not restarting: \(reason).")
        }
    }

    /// The age of the miner's log, for display.
    var logAge: TimeInterval? {
        tailer.cliModifiedAt.map { Date().timeIntervalSince($0) }
    }

    // MARK: Confirmation window

    /// Shows the countdown window and arms the automatic restart.
    private func beginConfirmation(for trigger: RestartTrigger) {
        let evidence = evidenceLine(for: trigger)
        let seconds = max(5, settings.countdownSeconds)
        pendingConfirmation = PendingConfirmation(trigger: trigger,
                                                  evidence: evidence,
                                                  secondsRemaining: seconds)
        logger.log("Proposing restart — \(trigger.title). \(trigger.detail) Evidence: \(evidence)")
        notify(title: trigger.title,
               body: "Restarting in \(seconds)s unless you cancel.")
        showConfirmationPanel()

        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let self, var pending = self.pendingConfirmation, pending.secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard self.pendingConfirmation != nil else { return }
                pending.secondsRemaining -= 1
                self.pendingConfirmation = pending
            }
            guard let self, self.pendingConfirmation != nil else { return }
            await self.confirmRestartNow()
        }
    }

    /// The user cancelled: no restart, and automatic restarts stay off until the miner runs again.
    func cancelPendingRestart() {
        countdownTask?.cancel()
        countdownTask = nil
        pendingConfirmation = nil
        closeConfirmationPanel()
        engine.recordRestartCancelled()
        logger.log("Restart cancelled by the user")
    }

    /// Proceeds with the restart, either because the countdown ended or the user clicked.
    func confirmRestartNow() async {
        countdownTask?.cancel()
        countdownTask = nil
        let origin = pendingConfirmation.map { "automatic — \($0.trigger.title)" }
            ?? "automatic"
        pendingConfirmation = nil
        closeConfirmationPanel()
        await performRestart(origin: origin)
    }

    /// The most useful raw log line to show as evidence.
    private func evidenceLine(for trigger: RestartTrigger) -> String {
        switch trigger {
        case .fatalError(let reason): return reason
        case .shutdown, .stopped:
            return engine.events.last(where: \.isNotable)?.text ?? trigger.detail
        case .frozen, .noProgress, .resetLoop:
            return trigger.detail
        }
    }

    // MARK: Actions

    /// Restarts the miner now, bypassing the confirmation window (menu action).
    func restartNow() async {
        await performRestart(origin: "manual — Restart miner now")
    }

    /// `origin` is recorded in the log so a restart can always be attributed afterwards.
    /// Without it, a hand-triggered restart and an automatic one looked identical in the log.
    private func performRestart(origin: String) async {
        guard !isRestarting else { return }
        isRestarting = true
        logger.log("Restart requested (\(origin))")
        engine.recordRestartStarted()

        // Logged directly rather than through a Task hop: hopping back to the main actor
        // deferred every line until the restart had finished, so they all carried the same
        // timestamp and the timings were useless for diagnosis. WatchdogLogger is already
        // safe to call from anywhere.
        let logger = self.logger
        let outcome = await restarter.restart { message in
            logger.log("Restart: \(message)")
        }

        isRestarting = false
        logger.log("Restart outcome: \(outcome)")

        switch outcome {
        case .succeeded:
            notify(title: "IOTA miner restarted", body: "The miner is running again.")
        case .workerDidNotAppear:
            notify(title: "Restart may have failed",
                   body: "The app was relaunched but the miner did not start.")
        case .launchFailed(let message):
            notify(title: "Restart failed", body: message)
        case .autoStartDisabled:
            notify(title: "Cannot restart automatically",
                   body: "Enable “start training on launch” in the IOTA app settings.")
        }
    }

    private func performLaunch() async {
        guard !isRestarting else { return }
        isRestarting = true
        engine.recordRestartStarted()
        let logger = self.logger
        let outcome = await restarter.launchHostApp { message in
            logger.log("Launch: \(message)")
        }
        isRestarting = false
        logger.log("Launch outcome: \(outcome)")
    }

    func pause(for duration: TimeInterval) {
        engine.pause(for: duration)
        logger.log("Paused for \(Int(duration / 60)) minutes")
    }

    func resumeAutomaticRestarts() {
        engine.resumeAutomaticRestarts()
        logger.log("Automatic restarts resumed by the user")
    }

    func openLogFolder() {
        NSWorkspace.shared.open(logger.logDirectory)
    }

    func openMinerLogFolder() {
        NSWorkspace.shared.open(tailer.directory)
    }

    func openHostApp() {
        NSWorkspace.shared.open(ProcessProbe.hostAppURL)
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        guard settings.notificationsEnabled else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard settings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: The panel

    /// A floating panel, visible on every Space, that does not require the app to be frontmost.
    private func showConfirmationPanel() {
        closeConfirmationPanel()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "IOTA Watchdog"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: RestartConfirmationView(coordinator: self))
        panel.center()
        panel.orderFrontRegardless()

        confirmationPanel = panel
    }

    private func closeConfirmationPanel() {
        confirmationPanel?.close()
        confirmationPanel = nil
    }
}
