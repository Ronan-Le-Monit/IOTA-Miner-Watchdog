//
//  Models.swift
//  IOTA_Miner_Dashboard
//
//  API response models (defensively decoded) and the tracked-miner model.
//

import Foundation

// MARK: - Flexible decoding helpers

private extension KeyedDecodingContainer {
    /// Decodes an Int that may arrive as Int, Double or String.
    func flexInt(_ key: Key) -> Int? {
        if let v = try? decode(Int.self, forKey: key) { return v }
        if let v = try? decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? decode(String.self, forKey: key) { return Int(v) }
        return nil
    }

    /// Decodes a Double that may arrive as Double, Int or String.
    func flexDouble(_ key: Key) -> Double? {
        if let v = try? decode(Double.self, forKey: key) { return v }
        if let v = try? decode(Int.self, forKey: key) { return Double(v) }
        if let v = try? decode(String.self, forKey: key) { return Double(v) }
        return nil
    }

    /// Decodes a Bool that may arrive as Bool, Int or String.
    func flexBool(_ key: Key) -> Bool? {
        if let v = try? decode(Bool.self, forKey: key) { return v }
        if let v = try? decode(Int.self, forKey: key) { return v != 0 }
        if let v = try? decode(String.self, forKey: key) { return (v as NSString).boolValue }
        return nil
    }

    func flexString(_ key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }
}

// MARK: - /runs

struct RunsResponse: Decodable {
    let runs: [Run]
}

/// A training run. Only `run_id` is needed; `metadata` and everything else is ignored
/// so decoding never fails on unexpected shapes.
struct Run: Decodable {
    let runId: String

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
    }
}

// MARK: - /miners

struct MinersResponse: Decodable {
    let miners: [Miner]
}

/// A miner currently training in a run. All numeric fields are decoded defensively and
/// unknown/extra fields are ignored.
struct Miner: Decodable, Equatable, Identifiable {
    var id: String { "\(hotkey)|\(coldkey)|\(runId)" }

    let timestamp: Int
    let layer: Int
    let minerUid: Int
    let uniqueMinerId: String
    let coldkey: String
    let hotkey: String
    let activationCount: Int
    let throughput: Double
    let incentive: Double
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let locationCountry: String?
    let registrationTime: Int
    let isActive: Bool
    let runId: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case layer
        case minerUid = "miner_uid"
        case uniqueMinerId = "unique_miner_id"
        case coldkey
        case hotkey
        case activationCount = "activation_count"
        case throughput
        case incentive
        case latitude
        case longitude
        case locationName = "location_name"
        case locationCountry = "location_country"
        case registrationTime = "registration_time"
        case isActive = "is_active"
        case runId = "run_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = c.flexInt(.timestamp) ?? 0
        layer = c.flexInt(.layer) ?? 0
        minerUid = c.flexInt(.minerUid) ?? 0
        uniqueMinerId = c.flexString(.uniqueMinerId) ?? ""
        coldkey = c.flexString(.coldkey) ?? ""
        hotkey = c.flexString(.hotkey) ?? ""
        activationCount = c.flexInt(.activationCount) ?? 0
        throughput = c.flexDouble(.throughput) ?? 0
        incentive = c.flexDouble(.incentive) ?? 0
        latitude = c.flexDouble(.latitude)
        longitude = c.flexDouble(.longitude)
        locationName = c.flexString(.locationName)
        locationCountry = c.flexString(.locationCountry)
        registrationTime = c.flexInt(.registrationTime) ?? 0
        isActive = c.flexBool(.isActive) ?? false
        runId = c.flexString(.runId) ?? ""
    }

    /// Memberwise initializer for tests and previews.
    init(
        timestamp: Int = 0,
        layer: Int = 0,
        minerUid: Int = 0,
        uniqueMinerId: String = "",
        coldkey: String,
        hotkey: String,
        activationCount: Int = 0,
        throughput: Double = 0,
        incentive: Double = 0,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        locationCountry: String? = nil,
        registrationTime: Int = 0,
        isActive: Bool = false,
        runId: String = ""
    ) {
        self.timestamp = timestamp
        self.layer = layer
        self.minerUid = minerUid
        self.uniqueMinerId = uniqueMinerId
        self.coldkey = coldkey
        self.hotkey = hotkey
        self.activationCount = activationCount
        self.throughput = throughput
        self.incentive = incentive
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.locationCountry = locationCountry
        self.registrationTime = registrationTime
        self.isActive = isActive
        self.runId = runId
    }
}

// MARK: - /sync

struct SyncInfo: Decodable {
    let lastSyncTimestamp: Int?
    let nextEstimate: Int?
    let secondNextEstimate: Int?

    enum CodingKeys: String, CodingKey {
        case lastSyncTimestamp = "last_sync_timestamp"
        case nextEstimate = "next_estimate"
        case secondNextEstimate = "second_next_estimate"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSyncTimestamp = (try? c.decodeIfPresent(Int.self, forKey: .lastSyncTimestamp)) ?? nil
        nextEstimate = (try? c.decodeIfPresent(Int.self, forKey: .nextEstimate)) ?? nil
        secondNextEstimate = (try? c.decodeIfPresent(Int.self, forKey: .secondNextEstimate)) ?? nil
    }
}

// MARK: - /progress

struct ProgressInfo: Decodable {
    let loss: Double?
    let activationCount: Int?
    let totalActivations: Int?
    let tokenCount: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case loss
        case activationCount = "activation_count"
        case totalActivations = "total_activations"
        case tokenCount = "token_count"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loss = (try? c.decode(Double.self, forKey: .loss)) ?? (try? c.decode(Int.self, forKey: .loss)).map(Double.init)
        activationCount = try? c.decodeIfPresent(Int.self, forKey: .activationCount)
        totalActivations = try? c.decodeIfPresent(Int.self, forKey: .totalActivations)
        tokenCount = try? c.decodeIfPresent(Int.self, forKey: .tokenCount)
        totalTokens = try? c.decodeIfPresent(Int.self, forKey: .totalTokens)
    }

    /// Training progress as a fraction 0...1, or nil if unavailable.
    var fraction: Double? {
        guard let done = activationCount, let total = totalActivations, total > 0 else { return nil }
        return min(1.0, Double(done) / Double(total))
    }
}

// MARK: - Tracked miner (persisted)

/// A miner the user wants to track, identified by a hotkey/coldkey prefix.
struct TrackedMiner: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var label: String
    var prefix: String

    init(id: UUID = UUID(), label: String, prefix: String) {
        self.id = id
        self.label = label
        self.prefix = prefix
    }

    static let defaults: [TrackedMiner] = [
        TrackedMiner(label: "Mac Mini (Ronan)", prefix: "5FjAQL4Y"),
        TrackedMiner(label: "MacBook Pro M5 Max", prefix: "5DXDN2UR"),
        TrackedMiner(label: "Mac Mini (Arnaud)", prefix: "5DFhoxZE")
    ]
}
