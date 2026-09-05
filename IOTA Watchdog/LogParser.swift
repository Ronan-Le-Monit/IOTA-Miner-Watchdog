//
//  LogParser.swift
//  IOTA Watchdog
//
//  Pure, side-effect-free parsing of the "IOTA Train at Home" log lines.
//
//  Two log files matter (see LogTailer):
//    • YYYY-MM-DD-cli.log  — the Python miner worker (loguru), ~500 lines/min while training
//    • YYYY-MM-DD-main.log — the Electron main process ([TrainingControl] lifecycle lines)
//
//  Every real entry starts with an electron-log prefix: "[2026-09-04 14:05:09.488] [info]  ".
//  Lines without that prefix are continuations (Python dict dumps, tracebacks, blank lines)
//  and are deliberately ignored — this also protects us from matching keywords inside the
//  multi-line capability list printed at startup.
//

import Foundation

// MARK: - Events

/// A meaningful thing that happened, extracted from one log line.
enum LogEventKind: Equatable {
    /// GET /miner/heartbeat?expected_phase=<phase> — emitted every ~35 s while alive.
    case heartbeat(phase: MinerPhase)
    /// POST /miner/submit_activation — real training progress.
    case submitActivation
    /// Generic liveness chatter (peer status, activation push). Proves the worker is writing.
    case chatter
    /// The layer moved between phases, e.g. training -> weights_uploading.
    /// This is the *real* phase signal; the heartbeat's `expected_phase` is a constant.
    case layerPhaseChange(actual: MinerPhase, expected: MinerPhase)

    /// "🚀 Starting miner 🚀" — the worker's run loop began.
    case minerStarting
    /// "✅ Miner <prefix> registered successfully in layer N on training epoch N"
    case registered(prefix: String)
    /// training.state accepted { state: '<state>' }
    case trainingState(TrainingState)
    /// "🔄 Resetting miner entire state!" — self-recovery after being kicked. NOT a failure.
    case resettingState

    /// "❌ Critical error in run_miner: <reason>" — fatal, the process exits within ~20 s.
    case criticalError(reason: String)
    /// "🛑 Miner shutdown complete" — definitive "training has stopped".
    case shutdownComplete
    /// The Electron host asked the worker to stop, i.e. the user pressed Stop Training.
    case controlStopRequested
    /// "[protocol] reconnect failed Error: Timed out waiting for welcome" — worker unreachable.
    case protocolReconnectFailed

    /// main.log: "[TrainingControl] miner process exited code=0 signal=null"
    case processExited(code: String, signal: String)
    /// main.log: "[TrainingControl] start request received"
    case startRequested
    /// main.log: "[TrainingControl] miner process spawned"
    case processSpawned

    /// Cannot reach the orchestrator (DNS/socket). Many of these mean "network is down",
    /// which is a reason NOT to restart.
    case orchestratorUnreachable
}

/// A parsed log line: when it happened and what it means.
struct LogEvent: Equatable {
    let timestamp: Date
    let kind: LogEventKind
    /// The original line, trimmed, kept for display as evidence in the confirmation window.
    let rawLine: String
}

/// A layer/training phase.
///
/// Note: the heartbeat's `expected_phase` parameter is **always** `training` (694/694 lines over
/// three days) — it states what the miner expects, not where it is. The live phase comes from
/// `layerPhaseChange` events instead.
enum MinerPhase: String, Equatable {
    case training
    case weightsUploading = "weights_uploading"
    case mergingPartitions = "merging_partitions"
    case other

    init(rawValue: String) {
        switch rawValue {
        case "training": self = .training
        case "weights_uploading": self = .weightsUploading
        case "merging_partitions": self = .mergingPartitions
        default: self = .other
        }
    }
}

/// The state the worker reports to the Electron host via `training.state`.
enum TrainingState: String, Equatable {
    case resetting
    case waitingTraining = "waiting_training"
    case training
    case trainingTick = "training_tick"
    case layerStateChange = "layer_state_change"
    case other

    init(rawValue: String) {
        switch rawValue {
        case "resetting": self = .resetting
        case "waiting_training": self = .waitingTraining
        case "training": self = .training
        case "training_tick": self = .trainingTick
        case "layer_state_change": self = .layerStateChange
        default: self = .other
        }
    }
}

// MARK: - Parser

/// Stateless line parser. `parse` returns nil for continuation lines and for the (very common)
/// noise lines listed in `Noise` below.
struct LogParser {

    /// Substrings that look alarming but occur constantly during healthy operation.
    /// Verified against three days of logs; none of these should ever trigger a restart.
    enum Noise {
        static let benign = [
            "has NaNs in Loss",                     // recovered by skipping the batch
            "Request is too stale",                 // EpistulaError, retried
            "attestation_required",
            "Connection reset by peer",
            "Broadcast peer status:",
            "High GPU memory usage detected",
            "register_set_queue_state exhausted retries",
            "PNP retry",
            "CASVersionMismatch",
            "Miner not registered",                 // followed by reset + re-registration
            "MinerNotRegisteredException",
            "Miner is moving state from",
            "RateLimitException",
            "No partitions found for layer",
            "Peer unreachable for forward activation"
        ]
    }

    /// Parses one raw log line. Returns nil when the line carries no event we care about.
    func parse(_ line: String) -> LogEvent? {
        guard let (timestamp, body) = Self.splitPrefix(line) else { return nil }
        guard let kind = kind(for: body) else { return nil }
        return LogEvent(timestamp: timestamp,
                        kind: kind,
                        rawLine: line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Kind matching

    private func kind(for body: String) -> LogEventKind? {
        // --- Fatal / lifecycle first: these must win over any noise check. ---

        if body.contains("Critical error in run_miner:") {
            let reason = body.components(separatedBy: "Critical error in run_miner:")
                .last?.trimmingCharacters(in: .whitespaces) ?? ""
            return .criticalError(reason: reason)
        }

        if body.contains("Miner shutdown complete") { return .shutdownComplete }

        if body.contains("Starting miner") && body.contains("🚀") { return .minerStarting }

        if body.contains("registered successfully in layer") {
            return .registered(prefix: Self.minerPrefix(in: body) ?? "")
        }

        if body.contains("Resetting miner entire state") { return .resettingState }

        // `control.stop` also appears as a quoted entry in the startup capability list.
        // Those are continuation lines (no timestamp) so they never reach here, but require
        // the request/accept wording as well so a single-line variant can't fool us either.
        if body.contains("control.stop"),
           body.contains("request received") || body.contains("accepted") {
            return .controlStopRequested
        }

        if body.contains("[protocol] reconnect failed") { return .protocolReconnectFailed }

        // --- main.log lifecycle ---

        if body.contains("[TrainingControl]") {
            if body.contains("miner process exited") {
                return .processExited(code: Self.value(of: "code=", in: body) ?? "?",
                                     signal: Self.value(of: "signal=", in: body) ?? "?")
            }
            if body.contains("miner process spawned") { return .processSpawned }
            if body.contains("start request received") { return .startRequested }
            return nil
        }

        // --- Progress signals ---

        if let range = body.range(of: "heartbeat?expected_phase=") {
            let raw = body[range.upperBound...].prefix { $0.isLetter || $0 == "_" }
            return .heartbeat(phase: MinerPhase(rawValue: String(raw)))
        }

        if body.contains("path: /miner/submit_activation") && body.contains("method: POST") {
            return .submitActivation
        }

        if let range = body.range(of: "training.state accepted { state: '") {
            let raw = body[range.upperBound...].prefix { $0 != "'" }
            return .trainingState(TrainingState(rawValue: String(raw)))
        }

        // --- Real phase changes: "Layer state change: {'layer': 1, 'expected_status': 'training',
        //     'actual_status': 'weights_uploading', ...}" (single line, most frequent source). ---

        if body.contains("Layer state change:") {
            let actual = Self.quotedValue(after: "'actual_status':", in: body)
            let expected = Self.quotedValue(after: "'expected_status':", in: body)
            if let actual {
                return .layerPhaseChange(actual: MinerPhase(rawValue: actual),
                                         expected: MinerPhase(rawValue: expected ?? ""))
            }
        }

        // --- Network outage evidence (checked before the noise filter deliberately) ---

        if body.contains("Cannot connect to host") || body.contains("Network is unreachable") {
            return .orchestratorUnreachable
        }

        // --- Everything alarming-but-normal stops here. ---

        if Noise.benign.contains(where: body.contains) { return nil }

        // --- Plain liveness chatter. ---

        if body.contains("Activation push RECV")
            || body.contains("P2P /peer/status from")
            || body.contains("Peer status dict has") {
            return .chatter
        }

        return nil
    }

    // MARK: Helpers

    /// Splits "[2026-09-04 14:05:09.488] [info]  <body>" into its date and body.
    /// Returns nil for continuation lines, blank lines and anything without the prefix.
    static func splitPrefix(_ line: String) -> (Date, String)? {
        guard line.hasPrefix("["), line.count > 25 else { return nil }
        let chars = Array(line)
        // Expect: [ yyyy - MM - dd _ HH : mm : ss . SSS ]
        guard chars[5] == "-", chars[8] == "-", chars[11] == " ",
              chars[14] == ":", chars[17] == ":", chars[20] == "." else { return nil }
        guard let closing = line.firstIndex(of: "]") else { return nil }

        func int(_ from: Int, _ to: Int) -> Int? { Int(String(chars[from..<to])) }
        guard let year = int(1, 5), let month = int(5 + 1, 8), let day = int(9, 11),
              let hour = int(12, 14), let minute = int(15, 17), let second = int(18, 20),
              let millis = int(21, 24) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = millis * 1_000_000
        guard let date = Self.calendar.date(from: components) else { return nil }

        let body = String(line[line.index(after: closing)...])
        return (date, body)
    }

    /// Local calendar — the log timestamps carry no timezone and are written in local time.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// Extracts the value that follows `key` up to the next space or end of line.
    private static func value(of key: String, in body: String) -> String? {
        guard let range = body.range(of: key) else { return nil }
        let value = body[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    /// Extracts a single-quoted value that follows `key`, e.g. `'actual_status': 'training'`.
    static func quotedValue(after key: String, in body: String) -> String? {
        guard let keyRange = body.range(of: key) else { return nil }
        let rest = body[keyRange.upperBound...]
        guard let open = rest.firstIndex(of: "'") else { return nil }
        let afterOpen = rest[rest.index(after: open)...]
        guard let close = afterOpen.firstIndex(of: "'") else { return nil }
        let value = afterOpen[..<close]
        return value.isEmpty ? nil : String(value)
    }

    /// Pulls the miner prefix out of "✅ Miner 5TESTAAA registered successfully in layer 1 …".
    private static func minerPrefix(in body: String) -> String? {
        guard let range = body.range(of: "Miner ") else { return nil }
        let token = body[range.upperBound...].prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }
}

// MARK: - Multi-line blocks

/// Wraps `LogParser` and additionally reassembles the multi-line objects that the Electron side
/// prints when they are too long for one line, e.g.
///
///     [2026-09-04 16:31:57.889] [info]  [Node Protocol Control] training.state accepted {
///       state: 'layer_state_change',
///       detail: 'Miner is moving state from training to weights_uploading',
///       runId: '4.12.10.5-tah',
///       layer: 1
///     }
///
/// Feed it every line in order. It returns at most one event per line: either the event the
/// single-line parser found, or the event completed by a closing `}`.
struct LogLineStream {
    private let parser = LogParser()

    /// State of a block we are in the middle of reading.
    private struct PendingBlock {
        let timestamp: Date
        var lines: [String]
        var state: String?
        var detail: String?
    }
    private var pending: PendingBlock?

    /// Consumes one line and returns the event it produced, if any.
    mutating func consume(_ line: String) -> LogEvent? {
        // Inside a multi-line block: collect fields until the closing brace.
        if var block = pending {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            block.lines.append(trimmed)

            if let state = LogParser.quotedValue(after: "state:", in: trimmed) { block.state = state }
            if let detail = LogParser.quotedValue(after: "detail:", in: trimmed) { block.detail = detail }

            // A new prefixed line means the block was never closed — abandon it and parse normally.
            if LogParser.splitPrefix(line) != nil {
                pending = nil
                return parser.parse(line)
            }

            if trimmed.hasPrefix("}") {
                pending = nil
                return Self.event(from: block)
            }
            pending = block
            return nil
        }

        // A prefixed line ending in "{" opens a multi-line object.
        if let (timestamp, body) = LogParser.splitPrefix(line),
           body.trimmingCharacters(in: .whitespaces).hasSuffix("{"),
           body.contains("training.state accepted") {
            pending = PendingBlock(timestamp: timestamp, lines: [line], state: nil, detail: nil)
            return nil
        }

        return parser.parse(line)
    }

    /// Turns a completed block into an event. Only `layer_state_change` carries information the
    /// single-line parser cannot already see.
    private static func event(from block: PendingBlock) -> LogEvent? {
        let raw = block.lines.joined(separator: " ")
        guard let state = block.state else { return nil }

        if TrainingState(rawValue: state) == .layerStateChange {
            // detail reads "Miner is moving state from <old> to <new>".
            if let detail = block.detail,
               let fromRange = detail.range(of: "state from "),
               let toRange = detail.range(of: " to ", range: fromRange.upperBound..<detail.endIndex) {
                let old = String(detail[fromRange.upperBound..<toRange.lowerBound])
                let new = String(detail[toRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return LogEvent(timestamp: block.timestamp,
                                kind: .layerPhaseChange(actual: MinerPhase(rawValue: new),
                                                        expected: MinerPhase(rawValue: old)),
                                rawLine: raw)
            }
        }

        return LogEvent(timestamp: block.timestamp,
                        kind: .trainingState(TrainingState(rawValue: state)),
                        rawLine: raw)
    }
}
