//
//  MinerLookup.swift
//  IOTA_Miner_Dashboard
//
//  Pure, unit-testable lookup and ranking logic.
//

import Foundation

/// The resolved state of a tracked miner after searching all runs.
struct MinerLookupResult: Identifiable, Equatable {
    let tracked: TrackedMiner
    /// The matched miner, or nil if not found in any run.
    let miner: Miner?
    /// The run the miner was found in.
    let runId: String?
    /// 1-based rank within its run (by activation_count descending).
    let rank: Int?
    /// Number of miners in the run.
    let total: Int?

    var id: UUID { tracked.id }
    var isFound: Bool { miner != nil }
}

enum MinerLookup {
    /// Resolves a single tracked miner against the per-run miner lists.
    ///
    /// A miner matches if its `hotkey` **or** `coldkey` starts with the prefix
    /// (case-sensitive). The first match across all runs wins; a miner lives in
    /// exactly one run. Rank is its 1-based position when the run's miners are
    /// sorted by `activation_count` descending.
    static func result(for tracked: TrackedMiner, in runMiners: [String: [Miner]]) -> MinerLookupResult {
        // Sort run ids for deterministic iteration order (a miner lives in one run,
        // so the "first match" is unambiguous regardless, but determinism aids testing).
        for runId in runMiners.keys.sorted() {
            let miners = runMiners[runId] ?? []
            guard let match = miners.first(where: {
                $0.hotkey.hasPrefix(tracked.prefix) || $0.coldkey.hasPrefix(tracked.prefix)
            }) else { continue }

            let sorted = miners.sorted { $0.activationCount > $1.activationCount }
            let rank = (sorted.firstIndex(of: match) ?? 0) + 1
            return MinerLookupResult(
                tracked: tracked,
                miner: match,
                runId: runId,
                rank: rank,
                total: miners.count
            )
        }
        return MinerLookupResult(tracked: tracked, miner: nil, runId: nil, rank: nil, total: nil)
    }

    /// Resolves all tracked miners, preserving the tracked order.
    static func results(for tracked: [TrackedMiner], in runMiners: [String: [Miner]]) -> [MinerLookupResult] {
        tracked.map { result(for: $0, in: runMiners) }
    }
}
