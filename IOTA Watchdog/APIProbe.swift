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
    /// When the miner's run last completed a full synchronisation.
    var lastSyncAt: Date?
    /// When the run expects its next full synchronisation.
    var nextSyncAt: Date?
    /// How long ago the miner's run last synced.
    var runSyncAge: TimeInterval?
    /// The median sync age across all active runs, for comparison.
    var medianSyncAge: TimeInterval?
    /// How full the relevant run is — the run the miner is in, or the one it is queueing for.
    var occupancy: RunOccupancy?
    /// Set when the miner is in no run yet but the orchestrator has already named one for it.
    /// This is what the miner is waiting to get into.
    var queueingForRunID: String?

    /// True when this run has fallen far behind every other run, i.e. the run itself is dead
    /// rather than the miner. Restarting cannot help: the orchestrator puts the miner straight
    /// back into the same run.
    ///
    /// Measured 2026-09-06: a stalled run had last synced 63.9 hours earlier while the nine
    /// healthy runs had all synced within the last hour, median 0.5 h. The separation is not
    /// subtle, so the test is deliberately blunt.
    var runAppearsStalled: Bool {
        guard let age = runSyncAge, let median = medianSyncAge else { return false }
        return age > max(6 * 3600, median * 6)
    }
}

/// Looks up one miner by hotkey prefix across every active run.
struct APIProbe {

    /// Concrete on purpose — see the note in ProcessProbe about async requirements through
    /// `any` existentials aborting in optimized builds.
    var api = IOTAAPIClient()

    /// Fetches all runs and finds the miner whose hotkey or coldkey starts with `prefix`.
    /// A single failing run does not fail the whole probe.
    ///
    /// `queueingFor` is the run the miner's own log says the orchestrator named for it. It is
    /// used only when the miner is not yet in any run, to report what it is waiting to join.
    func observe(prefix: String, queueingFor: String? = nil) async -> APIObservation {
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

        // Capacity of every run. Optional: an older deployment without this endpoint should
        // cost the occupancy figures, not the whole probe.
        let occupancyByRun = (try? await client.fetchOccupancy()) ?? [:]

        let tracked = TrackedMiner(label: "local", prefix: prefix)
        let result = MinerLookup.result(for: tracked, in: minersByRun)

        guard let miner = result.miner else {
            // Reachable, but the miner is in no run — it is queueing. Report which run it is
            // waiting for and how full that run is, which is the useful part of the wait.
            return APIObservation(
                reachable: true,
                occupancy: queueingFor.flatMap { occupancyByRun[$0] },
                queueingForRunID: queueingFor
            )
        }

        // The synchronisation schedule of every run, not just ours. One run's sync age means
        // little on its own; against the others it says whether the run is alive at all.
        var lastSyncAt: Date?
        var nextSyncAt: Date?
        var syncAges: [TimeInterval] = []
        let referenceDate = Date()
        for runID in runIDs {
            guard let sync = try? await client.fetchSync(runID: runID),
                  let last = sync.lastSyncTimestamp else { continue }
            let lastDate = Date(timeIntervalSince1970: TimeInterval(last))
            syncAges.append(referenceDate.timeIntervalSince(lastDate))
            if runID == miner.runId {
                lastSyncAt = lastDate
                nextSyncAt = sync.nextEstimate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        }
        let median: TimeInterval? = syncAges.isEmpty
            ? nil
            : syncAges.sorted()[syncAges.count / 2]
        let ownAge = lastSyncAt.map { referenceDate.timeIntervalSince($0) }

        return APIObservation(
            reachable: true,
            activationCount: miner.activationCount,
            isActive: miner.isActive,
            runID: miner.runId,
            rank: result.rank,
            totalInRun: result.total,
            layer: miner.layer + 1,       // the API's layer is zero-based
            lastSyncAt: lastSyncAt,
            nextSyncAt: nextSyncAt,
            runSyncAge: ownAge,
            medianSyncAge: median,
            occupancy: occupancyByRun[miner.runId]
        )
    }
}
