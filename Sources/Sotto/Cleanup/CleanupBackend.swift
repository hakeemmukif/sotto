import Foundation

enum CleanupError: Error, Equatable {
    case missingKey(String)
    case backendUnavailable
    case requestFailed(status: Int, body: String)
    case requestFailedWithoutDetail(status: Int)
    case nonHTTPResponse
    case emptyResponse
}

// Named `Cleaner` rather than `CleanupBackend` because `CleanupBackend` is already the settings enum
// that chooses between these implementations.
protocol Cleaner: Sendable {
    func clean(_ transcript: String, system: String) async throws -> String
}

enum CleanupHTTP {
    // Only a connection-level failure is `.backendUnavailable`, because that is the one error the
    // orchestrator is allowed to degrade on (decision 3a: paste raw, amber pill). Anything else
    // propagates unchanged — a malformed request must never be mistaken for an offline server.
    private static let unavailableCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .timedOut,
    ]

    static func post(json: Data, to endpoint: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = json

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where unavailableCodes.contains(error.code) {
            throw CleanupError.backendUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw CleanupError.nonHTTPResponse
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                throw CleanupError.requestFailedWithoutDetail(status: http.statusCode)
            }
            throw CleanupError.requestFailed(status: http.statusCode, body: body)
        }
        return data
    }
}
