//
//  APIProbe.swift
//  IOTA Watchdog
//
//  Second opinion from the public Macrocosmos API: is the network still crediting this miner
//  with activations? The local logs can look busy while the orchestrator has stopped counting,
//  so the no-progress rule requires both local and remote evidence before restarting.
//
//  Reuses the shared IOTAAPIClient and MinerLookup from the iOS dashboard app.
//

import Foundation

/// What the API says about the local miner right now.
struct APIObservation: Equatable {
    var reachable: Bool
    /// Nil when the miner is in no active run ("not found"), which is normal while it is down.
    var activationCount: Int?
    var isActive: Bool?
    var runID: String?
    var rank: Int?
    var totalInRun: Int?
    var layer: Int?
}

/// Looks up one miner by hotkey prefix across every active run.
struct APIProbe {

    /// Concrete on purpose — see the note in ProcessProbe about async requirements through
    /// `any` existentials aborting in optimized builds.
    var api = IOTAAPIClient()

    /// Fetches all runs and finds the miner whose hotkey or coldkey starts with `prefix`.
    /// A single failing run does not fail the whole probe.
    func observe(prefix: String) async -> APIObservation {
        // Bind the client locally so `self` stays out of the concurrent closures below.
        let client = api

        let runIDs: [String]
        do {
            runIDs = try await client.fetchRunIDs()
        } catch {
            return APIObservation(reachable: false)
        }

        // Fetched one run at a time on purpose. The concurrent `withTaskGroup` version worked in
        // Debug but broke in optimized builds: the child fetches returned nothing and the app
        // aborted with "Pure virtual function called!" inside Swift's task-completion path.
        // Eleven sequential requests take a few seconds and this runs once every five minutes,
        // so the concurrency bought nothing worth that risk.
        var minersByRun: [String: [Miner]] = [:]
        for runID in runIDs {
            do { minersByRun[runID] = try await client.fetchMiners(runID: runID) }
            catch { minersByRun[runID] = [] }
        }

        let tracked = TrackedMiner(label: "local", prefix: prefix)
        let result = MinerLookup.result(for: tracked, in: minersByRun)

        guard let miner = result.miner else {
            // Reachable, but the miner is in no run. Not an outage.
            return APIObservation(reachable: true)
        }

        return APIObservation(
            reachable: true,
            activationCount: miner.activationCount,
            isActive: miner.isActive,
            runID: miner.runId,
            rank: result.rank,
            totalInRun: result.total,
            layer: miner.layer + 1        // the API's layer is zero-based
        )
    }
}
