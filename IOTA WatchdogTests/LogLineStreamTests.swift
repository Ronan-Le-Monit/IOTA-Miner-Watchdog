//
//  LogLineStreamTests.swift
//  IOTA WatchdogTests
//
//  Phase-change parsing: the single-line Python variant and the multi-line Electron block.
//  Fixtures are real lines from ~/Library/Logs/IOTA Train at Home/, hotkeys anonymised.
//

import XCTest
@testable import IOTA_Watchdog

final class LayerPhaseTests: XCTestCase {

    private let parser = LogParser()

    /// The most frequent source: a single loguru WARNING carrying expected and actual status.
    func testSingleLineLayerStateChange() throws {
        let line = "[2026-09-04 16:31:57.892] [info]  2026-09-04 16:31:57.891 | WARNING  | subnet.miner_api_client:parse_response:572 - Layer state change: {'layer': 1, 'expected_status': 'training', 'actual_status': 'weights_uploading', 'message': 'Layer 1 is not in the expected state training, actual: weights_uploading'}"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .layerPhaseChange(actual: .weightsUploading, expected: .training))
    }

    func testSingleLineLayerStateChangeBackToTraining() throws {
        let line = "[2026-09-04 01:21:24.500] [info]  2026-09-04 01:21:24.500 | WARNING  | subnet.miner_api_client:parse_response:572 - Layer state change: {'layer': 2, 'expected_status': 'weights_uploading', 'actual_status': 'training', 'message': 'x'}"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .layerPhaseChange(actual: .training, expected: .weightsUploading))
    }

    /// The heartbeat's expected_phase is a constant and must not be mistaken for the live phase.
    func testHeartbeatPhaseIsAlwaysTrainingAndIsNotAPhaseChange() throws {
        let line = "[2026-09-04 15:10:10.590] [info]  2026-09-04 15:10:10.589 | DEBUG    | subnet.common_api_client:orchestrator_request:34 - Making orchestrator request | method: GET | path: /miner/heartbeat?expected_phase=training"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .heartbeat(phase: .training))
    }
}

final class LogLineStreamTests: XCTestCase {

    /// Real multi-line block (hotkeys anonymised) from 2026-09-04-cli.old.log line 41123.
    private let block = [
        "[2026-09-04 16:31:57.889] [info]  [Node Protocol Control] training.state accepted {",
        "  state: 'layer_state_change',",
        "  detail: 'Miner is moving state from training to weights_uploading',",
        "  runId: '4.12.10.5-tah',",
        "  layer: 1",
        "}"
    ]

    func testMultiLineBlockYieldsPhaseChangeOnClosingBrace() throws {
        var stream = LogLineStream()
        for line in block.dropLast() {
            XCTAssertNil(stream.consume(line), "no event before the closing brace: \(line)")
        }
        let event = try XCTUnwrap(stream.consume(block.last!))
        XCTAssertEqual(event.kind, .layerPhaseChange(actual: .weightsUploading, expected: .training))
        // The timestamp is the one from the opening line, not the closing brace.
        XCTAssertEqual(event.timestamp, LogParser.splitPrefix(block[0])!.0)
    }

    func testMultiLineBlockMergingPartitionsToTraining() throws {
        var stream = LogLineStream()
        let lines = [
            "[2026-09-04 01:21:24.523] [info]  [Node Protocol Control] training.state accepted {",
            "  state: 'layer_state_change',",
            "  detail: 'Miner is moving state from merging_partitions to training',",
            "  runId: '4.12.10.3-tah',",
            "  layer: 2",
            "}"
        ]
        for line in lines.dropLast() { _ = stream.consume(line) }
        let event = try XCTUnwrap(stream.consume(lines.last!))
        XCTAssertEqual(event.kind, .layerPhaseChange(actual: .training, expected: .mergingPartitions))
    }

    /// Single-line events must still flow through the stream unchanged.
    func testStreamPassesThroughSingleLineEvents() throws {
        var stream = LogLineStream()
        let tick = "[2026-09-04 16:31:57.897] [info]  [Node Protocol Control] training.state accepted { state: 'training_tick', runId: '4.12.10.5-tah', layer: 1 }"
        let event = try XCTUnwrap(stream.consume(tick))
        XCTAssertEqual(event.kind, .trainingState(.trainingTick))
    }

    /// The startup capability list is also a multi-line block, but not a training.state one,
    /// so it must never open a pending block nor produce a control-stop event.
    func testCapabilityBlockProducesNothing() {
        var stream = LogLineStream()
        let lines = [
            "[2026-09-04 12:36:38.355] [info]  [protocol] connected + welcomed {",
            "  sessionId: '9f79e18d-73f9-41ca-b8ff-2aa469c23eb3',",
            "  serverCapabilities: [",
            "    'control.start',",
            "    'control.stop',",
            "    'control.configure',",
            "  ]",
            "}"
        ]
        for line in lines {
            XCTAssertNil(stream.consume(line), "should produce nothing: \(line)")
        }
    }

    /// If a block is never closed (log truncated at rotation), the next prefixed line must be
    /// parsed normally rather than swallowed forever.
    func testUnclosedBlockRecoversOnNextPrefixedLine() throws {
        var stream = LogLineStream()
        _ = stream.consume(block[0])
        _ = stream.consume(block[1])
        let shutdown = "[2026-09-04 16:32:00.000] [info]  2026-09-04 16:32:00.000 | INFO     | miner.new_miner:run_miner:1940 - 🛑 Miner shutdown complete"
        let event = try XCTUnwrap(stream.consume(shutdown))
        XCTAssertEqual(event.kind, .shutdownComplete)
    }
}
