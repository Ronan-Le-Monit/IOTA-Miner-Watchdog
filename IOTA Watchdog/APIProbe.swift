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

    var api: any IOTAAPI = IOTAAPIClient()

    /// Fetches all runs and finds the miner whose hotkey or coldkey starts with `prefix`.
    /// A single failing run does not fail the whole probe.
    func observe(prefix: String) async -> APIObservation {
        // Bind the client locally: capturing `self.api` implicitly inside the task group below
        // crashes at runtime (EXC_BAD_ACCESS in libswift_Concurrency), so keep `self` out of the
        // concurrent closures entirely.
        let client = api

        let runIDs: [String]
        do {
            runIDs = try await client.fetchRunIDs()
        } catch {
            return APIObservation(reachable: false)
        }

        var minersByRun: [String: [Miner]] = [:]
        await withTaskGroup(of: (String, [Miner]).self) { group in
            for runID in runIDs {
                group.addTask {
                    do { return (runID, try await client.fetchMiners(runID: runID)) }
                    catch { return (runID, []) }
                }
            }
            for await (runID, miners) in group { minersByRun[runID] = miners }
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
