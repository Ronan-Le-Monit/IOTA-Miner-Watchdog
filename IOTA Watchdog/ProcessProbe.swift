//
//  ProcessProbe.swift
//  IOTA Watchdog
//
//  Cheap local checks that answer "is the miner actually running?" without touching the logs.
//
//  Three independent signals:
//    • the Python worker process    — pgrep for "ai.macrocosmos.iota.tah.worker"
//    • the worker's control server  — GET http://127.0.0.1:8010/health returns 200 while it lives
//    • the Electron host app        — NSRunningApplication for com.electron.iota-train-at-home
//
//  Port 8009 is the worker's visualization server and is useless as a health signal (it answers
//  404 for every path), so it is deliberately not used.
//

import Foundation
import AppKit

/// One observation of the miner's local state.
struct ProcessSnapshot: Equatable {
    /// PIDs of the worker process(es). The app spawns one main worker plus helper children.
    var workerPIDs: [pid_t] = []
    /// True when 127.0.0.1:8010/health answered 200 with `ok: true`.
    var controlServerHealthy = false
    /// True when the Electron host app is running.
    var hostAppRunning = false
    /// The host app's PID, when running.
    var hostAppPID: pid_t?

    /// Either signal is enough to call the worker alive: the health port can be briefly refused
    /// during startup while the process already exists, and vice versa during shutdown.
    var workerRunning: Bool { !workerPIDs.isEmpty || controlServerHealthy }
}

/// The real probe.
///
/// Deliberately a concrete type rather than something behind a protocol: calling an **async**
/// protocol requirement through an `any` existential miscompiles under optimization, and the
/// Release build aborted with "Pure virtual function called!" seconds after launch. The testable
/// seam lives in WatchdogEngine, which takes plain `ProcessSnapshot` values.
struct ProcessProbe {

    /// Command-line fragment unique to the miner worker.
    static let workerPattern = "ai.macrocosmos.iota.tah.worker"
    /// Bundle identifier of the Electron host app.
    static let hostBundleID = "com.electron.iota-train-at-home"
    /// Where the host app is installed.
    static let hostAppURL = URL(fileURLWithPath: "/Applications/IOTA Train at Home.app")

    private let healthURL = URL(string: "http://127.0.0.1:8010/health")!
    private let healthTimeout: TimeInterval = 2

    func snapshot() async -> ProcessSnapshot {
        var snapshot = ProcessSnapshot()
        snapshot.workerPIDs = Self.workerPIDs()

        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: Self.hostBundleID)
        snapshot.hostAppRunning = !hosts.isEmpty
        snapshot.hostAppPID = hosts.first?.processIdentifier

        snapshot.controlServerHealthy = await controlServerIsHealthy()
        return snapshot
    }

    // MARK: Worker process

    /// PIDs whose command line contains the worker pattern, via `pgrep -f`.
    static func workerPIDs() -> [pid_t] {
        let output = runCommand("/usr/bin/pgrep", ["-f", workerPattern])
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Control server

    /// GET /health on the worker's control port. Any failure means "not healthy", never an error:
    /// a refused connection is the normal answer when the miner is down.
    private func controlServerIsHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = healthTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = healthTimeout
        configuration.timeoutIntervalForResource = healthTimeout
        let session = URLSession(configuration: configuration)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            // Body looks like {"ok":true,"connected":true,"sessionId":…}
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["ok"] as? Bool ?? false
        } catch {
            return false
        }
    }

    // MARK: Shell helper

    /// Runs a command and returns stdout. Returns "" on any failure — callers treat that as
    /// "no result", which is the safe reading for every use here.
    @discardableResult
    static func runCommand(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
