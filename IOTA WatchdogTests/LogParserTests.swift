//
//  LogParserTests.swift
//  IOTA WatchdogTests
//
//  Every fixture below is a verbatim line taken from
//  ~/Library/Logs/IOTA Train at Home/ (2026-09-02 … 2026-09-04).
//

import XCTest
@testable import IOTA_Watchdog

final class LogParserTests: XCTestCase {

    private let parser = LogParser()

    // MARK: - Prefix parsing

    func testParsesTimestampInLocalTime() throws {
        let line = "[2026-09-04 14:05:09.488] [info]  2026-09-04 14:05:09.488 | INFO     | miner.training.activation_queue:_fetch_activations_push_based:914 - Activation push RECV | pulled ingress async queue | id=65541ce0-dee4-418c-988d-449f52172872 dir=backward src_layer=2 tgt_layer=1"
        let event = try XCTUnwrap(parser.parse(line))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: event.timestamp)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 4)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 5)
        XCTAssertEqual(parts.second, 9)
    }

    func testIgnoresContinuationAndBlankLines() {
        // Python dict dumps and traceback bodies have no electron-log prefix.
        let continuations = [
            "",
            "  ",
            "                                                       'miner_status': 'training',",
            "Traceback (most recent call last):",
            "  File \"main_pool.py\", line 1, in main",
            "common.utils.exceptions.NanInfException: Loss for miner 5DXDN2UR has NaNs",
            "    'control.stop',",
            "  serverCapabilities: [",
            "not a log line at all"
        ]
        for line in continuations {
            XCTAssertNil(parser.parse(line), "should ignore: \(line)")
        }
    }

    /// The startup capability list contains the literal string `control.stop`. If that were
    /// treated as a stop request the watchdog would think the user stopped training at every
    /// launch and would never auto-restart.
    func testCapabilityListDoesNotLookLikeAStopRequest() {
        XCTAssertNil(parser.parse("    'control.stop',"))
        XCTAssertNil(parser.parse("[2026-09-04 12:36:38.355] [info]  [protocol] connected + welcomed {"))
    }

    // MARK: - Progress signals

    func testHeartbeatCarriesPhase() throws {
        let line = "[2026-09-04 15:10:10.590] [info]  2026-09-04 15:10:10.589 | DEBUG    | subnet.common_api_client:orchestrator_request:34 - Making orchestrator request | method: GET | path: /miner/heartbeat?expected_phase=training"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .heartbeat(phase: .training))
    }

    func testHeartbeatWithUnobservedPhase() throws {
        let line = "[2026-09-04 15:10:10.590] [info]  2026-09-04 15:10:10.589 | DEBUG    | subnet.common_api_client:orchestrator_request:34 - Making orchestrator request | method: GET | path: /miner/heartbeat?expected_phase=weights_uploading"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .heartbeat(phase: .weightsUploading))
    }

    func testSubmitActivation() throws {
        let line = "[2026-09-04 14:05:09.305] [info]  2026-09-04 14:05:09.305 | DEBUG    | subnet.common_api_client:orchestrator_request:34 - Making orchestrator request | method: POST | path: /miner/submit_activation"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .submitActivation)
    }

    /// A GET to all_layers_training is not activation progress.
    func testOtherOrchestratorRequestsAreNotProgress() {
        let line = "[2026-09-04 15:10:05.510] [info]  2026-09-04 15:10:05.510 | DEBUG    | subnet.common_api_client:orchestrator_request:34 - Making orchestrator request | method: GET | path: /miner/all_layers_training"
        XCTAssertNil(parser.parse(line))
    }

    func testChatterProvesLiveness() throws {
        let lines = [
            "[2026-09-04 15:10:04.112] [info]  2026-09-04 15:10:04.112 | DEBUG    | miner.p2p.stack:on_peer_status:289 - P2P /peer/status from 5CZdRcsL... (peer=ac109d4a692821c5...)",
            "[2026-09-04 15:10:10.144] [info]  2026-09-04 15:10:10.144 | DEBUG    | miner.new_miner:_peer_status_broadcast_loop:662 - Peer status dict has 71 entries"
        ]
        for line in lines {
            let event = try XCTUnwrap(parser.parse(line), line)
            XCTAssertEqual(event.kind, .chatter)
        }
    }

    // MARK: - Lifecycle

    func testMinerStarting() throws {
        let line = "[2026-09-04 12:36:38.548] [info]  2026-09-04 12:36:38.547 | INFO     | miner.new_miner:run_miner:1845 - 🚀 Starting miner 🚀"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .minerStarting)
    }

    func testRegisteredExtractsPrefix() throws {
        let line = "[2026-09-04 14:53:25.291] [info]  2026-09-04 14:53:25.291 | SUCCESS  | miner.new_miner:_apply_registration_response:1320 - ✅ Miner 5DXDN2UR registered successfully in layer 1 on training epoch 47"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .registered(prefix: "5DXDN2UR"))
    }

    func testTrainingStates() throws {
        let cases: [(String, TrainingState)] = [
            ("[2026-09-04 12:36:38.811] [info]  [Node Protocol Control] training.state accepted { state: 'resetting' }", .resetting),
            ("[2026-09-04 12:42:46.276] [info]  [Node Protocol Control] training.state accepted { state: 'waiting_training' }", .waitingTraining),
            ("[2026-09-04 12:42:50.276] [info]  [Node Protocol Control] training.state accepted { state: 'training' }", .training)
        ]
        for (line, expected) in cases {
            let event = try XCTUnwrap(parser.parse(line), line)
            XCTAssertEqual(event.kind, .trainingState(expected))
        }
    }

    func testTrainingTickWithRunAndLayerSuffix() throws {
        let line = "[2026-09-04 14:53:57.000] [info]  [Node Protocol Control] training.state accepted { state: 'training_tick', runId: '4.12.10.5-tah', layer: 1 }"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .trainingState(.trainingTick))
    }

    /// Self-recovery after being kicked from a run. Must never be read as a failure.
    func testResettingStateIsItsOwnEvent() throws {
        let line = "[2026-09-04 12:36:38.812] [info]  2026-09-04 12:36:38.806 | INFO     | miner.new_miner:reset_miner_state:1969 - 🔄 Resetting miner entire state!"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .resettingState)
    }

    // MARK: - Stop / fatal

    /// The definitive "training has stopped" line.
    func testShutdownComplete() throws {
        let line = "[2026-09-04 11:10:15.605] [info]  2026-09-04 11:10:15.604 | INFO     | miner.new_miner:run_miner:1940 - 🛑 Miner shutdown complete"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .shutdownComplete)
    }

    func testCriticalErrorCarriesReason() throws {
        let line = "[2026-09-04 11:09:56.105] [info]  2026-09-04 11:09:56.105 | ERROR    | miner.new_miner:run_miner:1883 - ❌ Critical error in run_miner: pseudo gradients for miner 5DXDN2UR has NaNs"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .criticalError(reason: "pseudo gradients for miner 5DXDN2UR has NaNs"))
    }

    func testProtocolReconnectFailed() throws {
        let line = "[2026-09-04 11:10:25.911] [info]  [protocol] reconnect failed Error: Timed out waiting for welcome"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .protocolReconnectFailed)
    }

    func testControlStopRequest() throws {
        // Wording follows the observed sibling commands (register.status / training.state);
        // no user-initiated stop appears in the available logs, so this shape is inferred.
        let line = "[2026-09-04 16:00:00.000] [info]  [Node Protocol Control] control.stop request received {}"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .controlStopRequested)
    }

    // MARK: - main.log

    func testProcessExitedCapturesCodeAndSignal() throws {
        let line = "[2026-09-04 11:10:16.742] [info]  [TrainingControl] miner process exited code=0 signal=null"
        let event = try XCTUnwrap(parser.parse(line))
        XCTAssertEqual(event.kind, .processExited(code: "0", signal: "null"))
    }

    func testStartRequestedAndSpawned() throws {
        let requested = try XCTUnwrap(parser.parse("[2026-09-04 12:36:24.043] [info]  [TrainingControl] start request received"))
        XCTAssertEqual(requested.kind, .startRequested)

        let spawned = try XCTUnwrap(parser.parse("[2026-09-04 12:36:24.305] [info]  [TrainingControl] miner process spawned"))
        XCTAssertEqual(spawned.kind, .processSpawned)
    }

    func testAutoUpdaterLinesAreIgnored() {
        XCTAssertNil(parser.parse("[2026-09-04 15:09:23.389] [info]  [AutoUpdater] Checking for update..."))
        XCTAssertNil(parser.parse("[2026-09-04 15:09:23.726] [info]  [AutoUpdater] Update not available."))
    }

    // MARK: - Network outage

    func testOrchestratorUnreachable() throws {
        let lines = [
            "[2026-09-03 01:21:35.000] [info]  2026-09-03 01:21:35.000 | ERROR    | subnet.common_api_client:orchestrator_request:97 - Cannot connect to host iota.api.macrocosmos.ai:443 ssl:default [nodename nor servname provided, or not known]",
            "[2026-09-03 01:21:36.000] [info]  2026-09-03 01:21:36.000 | ERROR    | subnet.common_api_client:orchestrator_request:97 - Cannot connect to host iota.api.macrocosmos.ai:443 ssl:default [Network is unreachable]"
        ]
        for line in lines {
            let event = try XCTUnwrap(parser.parse(line), line)
            XCTAssertEqual(event.kind, .orchestratorUnreachable)
        }
    }

    // MARK: - Noise that must never trigger anything

    func testBenignNoiseProducesNoEvent() {
        let noise = [
            "[2026-09-04 10:30:00.000] [info]  2026-09-04 10:30:00.000 | ERROR    | subnet.utils.vector_utils:check_for_nans_and_infs:137 - ❌ Miner has NaNs in Loss for miner 5DXDN2UR | 1 / 1 = 100.00%",
            "[2026-09-04 10:30:01.000] [info]  2026-09-04 10:30:01.000 | ERROR    | subnet.common_api_client:orchestrator_request:109 - Failed request after 3 attempts: 400, {\"detail\":{\"error\":\"Request is too stale\",\"message\":\"EpistulaError: Request is too stale\",\"name\":\"EpistulaError\"}}",
            "[2026-09-04 10:30:02.000] [info]  2026-09-04 10:30:02.000 | ERROR    | subnet.common_api_client:orchestrator_request:97 - Error making orchestrator request to endpoint /miner/submit_activation: 400 - {\"detail\":\"attestation_required\"}",
            "[2026-09-04 15:10:10.142] [info]  2026-09-04 15:10:10.142 | WARNING  | miner.new_miner:_broadcast_peer_status:568 - Broadcast peer status: 28/37 ok, 9 unreachable in 5004ms | errors: TimeoutError=9 | sample: [5DVCvuhN (relay=y, direct=4) -> TimeoutError: ]",
            "[2026-09-04 10:30:04.000] [info]  2026-09-04 10:30:04.000 | WARNING  | subnet.model.utils:log_gpu_memory_usage:41 - High GPU memory usage detected: 71GB -- after forward pass",
            "[2026-09-04 12:37:22.256] [info]  2026-09-04 12:37:22.256 | WARNING  | miner.utils.node_control_mixin:register_set_queue_state:221 - register_set_queue_state exhausted retries (3): POST /register/queue_state failed 503",
            "[2026-09-04 10:30:06.000] [info]  PNP retry 2/5: RuntimeError: connect timeout after 10s — backoff 1.5s",
            "[2026-09-04 10:30:07.000] [info]  2026-09-04 10:30:07.000 | WARNING  | miner.sync_v2.synced_collection:set_many:96 - set_many 'run-4_12_10_5-tah/node_registry/5DXDN2UR/last_keepalive': CASVersionMismatch",
            "[2026-09-04 14:48:07.292] [info]  2026-09-04 14:48:07.292 | WARNING  | miner.training.activation_queue:stop_activation_fetcher:201 - Activation fetcher task returned an exception: Miner not registered",
            "[2026-09-04 10:30:09.000] [info]  2026-09-04 10:30:09.000 | ERROR    | subnet.miner_api_client:submit_activation_request:383 - Error submitting activation: Miner is moving state from training to weights_uploading",
            "[2026-09-04 10:30:10.000] [info]  2026-09-04 10:30:10.000 | WARNING  | miner.utils.partition_merging:get_weight_partition_info:88 - No partitions found for layer 1",
            "[2026-09-04 10:30:11.000] [info]  2026-09-04 10:30:11.000 | INFO     | miner.new_miner:submit_weights:1701 - Pseudo gradients for miner 5DXDN2UR have mean nan and std nan"
        ]
        for line in noise {
            XCTAssertNil(parser.parse(line), "should be ignored: \(line.prefix(120))")
        }
    }

    /// "Skipping backward … due to loss/target fetch error" is an ERROR line but the miner
    /// carries on with the next activation.
    func testSkippedBackwardIsNotFatal() {
        let line = "[2026-09-04 10:30:12.000] [info]  2026-09-04 10:30:12.000 | ERROR    | miner.training.training:_run_backward_slices:513 - Skipping backward for activation e06bb534-22a5-424f-9aa2-54e9910d4302 due to loss/target fetch error: Loss for miner 5DXDN2UR has NaNs"
        XCTAssertNil(parser.parse(line))
    }
}
