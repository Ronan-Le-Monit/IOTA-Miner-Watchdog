//
//  APIProbeLiveTests.swift
//  IOTA WatchdogTests
//
//  Hits the real Macrocosmos API. Skipped when the network or the API is unavailable so the
//  suite still passes offline.
//

import XCTest
@testable import IOTA_Watchdog

final class APIProbeLiveTests: XCTestCase {

    /// The miner running on this Mac.
    func testResolvesLocalMinerAgainstTheLiveAPI() async throws {
        let observation = await APIProbe().observe(prefix: "5TESTAAA")

        try XCTSkipUnless(observation.reachable, "API not reachable — skipping live check")

        // The miner may legitimately be in no run (not training); only assert shape when found.
        if let activations = observation.activationCount {
            XCTAssertGreaterThanOrEqual(activations, 0)
            XCTAssertNotNil(observation.runID)
            let rank = try XCTUnwrap(observation.rank)
            let total = try XCTUnwrap(observation.totalInRun)
            XCTAssertGreaterThan(rank, 0)
            XCTAssertLessThanOrEqual(rank, total)
            // Layer is displayed 1-based.
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(observation.layer), 1)
        }
    }

    /// An unknown prefix must read as "reachable but not found", never as an outage — the
    /// no-progress rule depends on telling those two apart.
    func testUnknownPrefixIsReachableButNotFound() async throws {
        let observation = await APIProbe().observe(prefix: "zzzzNoSuchMiner")
        try XCTSkipUnless(observation.reachable, "API not reachable — skipping live check")
        XCTAssertNil(observation.activationCount)
        XCTAssertNil(observation.runID)
    }
}
