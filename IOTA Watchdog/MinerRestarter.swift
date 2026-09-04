//
//  MinerRestarter.swift
//  IOTA Watchdog
//
//  Restarts the miner by quitting and relaunching the Electron host app.
//
//  Why not click Start/Stop in the app?
//    • The tray menu's labels and enabled state change with lifecycle ("Start Training",
//      "Stop Training", "Cancel Start", disabled while disconnected), so UI scripting needs
//      Accessibility permission and breaks on every app update.
//    • The app's start command is internal IPC between its renderer and main process.
//    • The worker's control socket on 127.0.0.1:8010 dies with the worker and is bound to the
//      Electron host's PID, so we cannot send it a start.
//    • Relaunching is the app's own supported path: `autoStartTrainingOnStartup` is true in
//      ~/Library/Application Support/IOTA Train at Home/preferences.json, so a fresh launch
//      starts training by itself. It also clears wedged state on the Electron side.
//

import Foundation
import AppKit

/// Outcome of a restart attempt.
enum RestartOutcome: Equatable {
    /// The app relaunched and the worker was seen again.
    case succeeded
    /// The app relaunched but the worker did not appear in time.
    case workerDidNotAppear
    /// The app could not be launched at all.
    case launchFailed(String)
    /// The app's own setting means a launch will not start training.
    case autoStartDisabled
}

/// Quits and relaunches the miner's host app.
struct MinerRestarter {

    /// Where the host app lives.
    var appURL: URL = ProcessProbe.hostAppURL
    /// The probe used to confirm the outcome.
    var probe = ProcessProbe()

    /// How long to wait for a graceful quit before forcing it.
    var quitTimeout: TimeInterval = 30
    /// How long to wait for surviving worker processes to disappear.
    var workerExitTimeout: TimeInterval = 15
    /// Pause between quit and launch, so the app's own cleanup finishes.
    var relaunchDelay: TimeInterval = 5
    /// How long to wait for the worker to come back after launching.
    var confirmTimeout: TimeInterval = 90

    /// Reads the host app's preference file to check that launching will start training.
    /// Returns nil when the file cannot be read, which is treated as "assume it is enabled".
    static func autoStartOnLaunchEnabled() -> Bool? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IOTA Train at Home/preferences.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["autoStartTrainingOnStartup"] as? Bool
    }

    /// Performs the full restart. Long-running: quit, confirm death, relaunch, confirm life.
    func restart(log: @escaping (String) -> Void = { _ in }) async -> RestartOutcome {
        if Self.autoStartOnLaunchEnabled() == false {
            log("The IOTA app is set not to start training on launch — cannot restart automatically.")
            return .autoStartDisabled
        }

        // 1. Ask the app to quit.
        let hosts = NSRunningApplication.runningApplications(
            withBundleIdentifier: ProcessProbe.hostBundleID)
        if hosts.isEmpty {
            log("The IOTA app is not running; launching it.")
        } else {
            log("Quitting the IOTA app.")
            for host in hosts { host.terminate() }

            let deadline = Date().addingTimeInterval(quitTimeout)
            while Date() < deadline,
                  !NSRunningApplication.runningApplications(
                    withBundleIdentifier: ProcessProbe.hostBundleID).isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }

            let survivors = NSRunningApplication.runningApplications(
                withBundleIdentifier: ProcessProbe.hostBundleID)
            if !survivors.isEmpty {
                log("The app did not quit in \(Int(quitTimeout))s; forcing it.")
                for host in survivors { host.forceTerminate() }
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // 2. Make sure no worker process survived the app.
        var workers = ProcessProbe.workerPIDs()
        if !workers.isEmpty {
            log("Terminating \(workers.count) leftover worker process(es).")
            ProcessProbe.runCommand("/usr/bin/pkill", ["-f", ProcessProbe.workerPattern])

            let deadline = Date().addingTimeInterval(workerExitTimeout)
            while Date() < deadline, !ProcessProbe.workerPIDs().isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            workers = ProcessProbe.workerPIDs()
            if !workers.isEmpty {
                log("Worker still present after \(Int(workerExitTimeout))s; killing it.")
                ProcessProbe.runCommand("/usr/bin/pkill", ["-9", "-f", ProcessProbe.workerPattern])
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // 3. Relaunch without stealing focus.
        try? await Task.sleep(for: .seconds(relaunchDelay))
        log("Launching the IOTA app.")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL,
                                                            configuration: configuration)
        } catch {
            log("Launch failed: \(error.localizedDescription)")
            return .launchFailed(error.localizedDescription)
        }

        // 4. Confirm the worker came back.
        let deadline = Date().addingTimeInterval(confirmTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            let snapshot = await probe.snapshot()
            if snapshot.workerRunning {
                log("Miner process is running again.")
                return .succeeded
            }
        }

        log("The worker did not appear within \(Int(confirmTimeout))s.")
        return .workerDidNotAppear
    }

    /// Launches the host app without quitting anything (used when the app is simply not running).
    func launchHostApp(log: @escaping (String) -> Void = { _ in }) async -> RestartOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL,
                                                            configuration: configuration)
            log("Launched the IOTA app.")
            return .succeeded
        } catch {
            log("Launch failed: \(error.localizedDescription)")
            return .launchFailed(error.localizedDescription)
        }
    }
}
