//
//  MenuView.swift
//  IOTA Watchdog
//
//  The menu-bar popover: current state, the evidence behind it, the controls, recent events.
//

import SwiftUI

struct MenuView: View {
    @ObservedObject var coordinator: WatchdogCoordinator
    @ObservedObject var settings: WatchdogSettings
    @ObservedObject var engine: WatchdogEngine
    @ObservedObject var power: PowerMonitor

    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            evidence
            Divider()
            controls
            if !engine.events.isEmpty {
                Divider()
                history
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        // Painted behind the padding, not inside it. Without this the view inherits the menu
        // bar popover's translucent material and the header text is unreadable over bright
        // windows behind it.
        .background(Theme.background)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("IOTA WATCHDOG")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.titleText)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(engine.state.tint)
                    .frame(width: 9, height: 9)
                    .shadow(color: engine.state.tint.opacity(0.8), radius: 3)
                Text(engine.state.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if coordinator.isRestarting {
                    ProgressView().controlSize(.small)
                }
            }

            if case .needsAttention(let reason) = engine.state {
                Text("Automatic restarts stopped: \(reason).")
                    .font(.caption)
                    .foregroundStyle(Theme.inactiveRed)
            }
            if !settings.autoRestartEnabled {
                Text("Watching only — automatic restart is off. Turn it on below when you are ready.")
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xFBBF24))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if engine.state == .stoppedByUser {
                Button("Resume automatic restarts") { coordinator.resumeAutomaticRestarts() }
                    .font(.caption)
            }
        }
    }

    // MARK: Evidence

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let prefix = settings.localPrefix {
                row("Watching miner", prefix + (settings.localPrefixOverride.isEmpty ? "" : " (manual)"))
            } else {
                Text("No miner found on this Mac. Set the hotkey below, "
                     + "or start IOTA Train at Home once so its wallet exists.")
                    .font(.caption)
                    .foregroundStyle(Theme.inactiveRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("Miner process", coordinator.workerText)
            row("Log age", formatAge(coordinator.logAge))
            row("Last activation", formatAge(engine.lastProgressAt.map { Date().timeIntervalSince($0) }))
            // Say what will happen and when, rather than looking idle while a timer runs down.
            if let deadline = engine.noProgressDeadline,
               let age = engine.progressAge, age > 5 * 60,
               settings.autoRestartEnabled,
               deadline > Date() {
                row("Restart if still idle", deadline.formatted(date: .omitted, time: .shortened))
            }
            if let api = coordinator.lastAPI {
                if let rank = api.rank, let total = api.totalInRun {
                    row("Rank", "#\(rank) of \(total)")
                }
                if let activations = api.activationCount {
                    row("Activations", "\(activations)")
                }
                if let run = api.runID { row("Run", run) }
                if !api.reachable { row("API", "unreachable") }
            }
            if let sleep = coordinator.sleepWarning {
                Text(sleep)
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xFBBF24))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.mutedText)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Restart the miner automatically", isOn: $settings.autoRestartEnabled)
            Toggle("Keep the Mac awake while training", isOn: $settings.keepAwakeEnabled)
            Toggle("Start the watchdog at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    launchError = settings.setLaunchAtLogin(enabled)
                    launchAtLogin = settings.launchAtLogin
                }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(Theme.inactiveRed)
            }

            HStack(spacing: 6) {
                Text("Hotkey")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedText)
                TextField(settings.detectedHotkey?.prefix ?? "e.g. 5TESTAAA",
                          text: $settings.localPrefixOverride)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                if !settings.localPrefixOverride.isEmpty {
                    Button("Auto") { settings.localPrefixOverride = "" }
                        .font(.caption)
                }
            }

            HStack {
                Button("Restart miner now") { Task { await coordinator.restartNow() } }
                    .disabled(coordinator.isRestarting)
                Button("Pause 1 h") { coordinator.pause(for: 3600) }
            }
            .font(.caption)
        }
        .toggleStyle(.switch)
        .font(.caption)
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.titleText)
            ForEach(engine.events.suffix(6).reversed()) { event in
                HStack(alignment: .top, spacing: 6) {
                    Text(event.at, format: .dateTime.hour().minute())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.mutedText)
                    Text(event.text)
                        .font(.system(size: 10))
                        .foregroundStyle(event.isNotable ? Theme.primaryText : Theme.secondaryMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        // Spacing is 0 here so each section sets its own; a uniform stack spacing made the
        // Support row look like just another line of buttons.
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Miner logs") { coordinator.openMinerLogFolder() }
                Button("Watchdog log") { coordinator.openLogFolder() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)

            // Hidden when nothing is configured, so a release never ships a dead button.
            if !AppLinks.donations.isEmpty {
                HStack(spacing: 8) {
                    Text("Support")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.activeGreen)
                    ForEach(AppLinks.donations) { link in
                        Button(link.label) { NSWorkspace.shared.open(link.url) }
                            .font(.caption)
                    }
                    Spacer()
                }
                .padding(.vertical, 14)
            }

            if let repository = AppLinks.repository {
                HStack {
                    Spacer()
                    // Full size and fixed, so the label is never clipped. The footer used to
                    // force .caption on everything, which truncated it.
                    Button("Report an issue") { NSWorkspace.shared.open(repository) }
                        .fixedSize()
                }
            }
        }
    }
}

extension WatchdogCoordinator {
    /// "running (pid 48007)" / "not running", plus the health port's opinion.
    var workerText: String {
        guard let snapshot = engine.lastSnapshot else { return "—" }
        if snapshot.workerRunning {
            let pid = snapshot.workerPIDs.first.map { " (pid \($0))" } ?? ""
            return "running\(pid)"
        }
        return snapshot.hostAppRunning ? "not running" : "app not running"
    }

    /// Warns when the Mac is configured to sleep almost immediately, which stops mining.
    var sleepWarning: String? {
        guard !power.isHoldingSleepAssertion else { return nil }
        let sleep = PowerMonitor.idleSleepMinutes()
        guard let ac = sleep.ac, ac > 0, ac <= 5 else { return nil }
        return "This Mac sleeps after \(ac) min on power, which stops mining. "
             + "Turn on “Keep the Mac awake while training”."
    }
}
