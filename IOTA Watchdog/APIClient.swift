//
//  APIClient.swift
//  IOTA_Miner_Dashboard
//
//  Networking layer. Injectable via the `IOTAAPI` protocol for testability.
//

import Foundation

/// Abstraction over the IOTA public API so the view model can be unit-tested
/// with a mock.
protocol IOTAAPI: Sendable {
    /// All run ids from `/runs`.
    func fetchRunIDs() async throws -> [String]
    /// Miners training in a run from `/miners?run_id=…`.
    func fetchMiners(runID: String) async throws -> [Miner]
    /// Sync estimates from `/sync?run_id=…`.
    func fetchSync(runID: String) async throws -> SyncInfo
    /// Training progress from `/progress?run_id=…`.
    func fetchProgress(runID: String) async throws -> ProgressInfo
}

enum APIError: LocalizedError {
    case badResponse(Int)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Server returned status \(code)."
        case .invalidURL: return "Invalid request URL."
        }
    }
}

/// Live client hitting the Macrocosmos IOTA mainnet API.
///
/// Responses are gzip-compressed JSON; `URLSession` decompresses transparently.
struct IOTAAPIClient: IOTAAPI {
    let baseURL: URL
    let session: URLSession

    init(
        baseURL: URL = URL(string: "https://iota-web.api.macrocosmos.ai/mainnet")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchRunIDs() async throws -> [String] {
        let response = try await get("runs", as: RunsResponse.self)
        return response.runs.map(\.runId)
    }

    func fetchMiners(runID: String) async throws -> [Miner] {
        let response = try await get("miners", query: ["run_id": runID], as: MinersResponse.self)
        return response.miners
    }

    func fetchSync(runID: String) async throws -> SyncInfo {
        try await get("sync", query: ["run_id": runID], as: SyncInfo.self)
    }

    func fetchProgress(runID: String) async throws -> ProgressInfo {
        try await get("progress", query: ["run_id": runID], as: ProgressInfo.self)
    }
}
