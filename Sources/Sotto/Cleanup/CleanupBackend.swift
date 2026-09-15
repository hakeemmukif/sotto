import Foundation

enum CleanupError: Error, Equatable, CustomStringConvertible {
    case missingKey(String)
    case backendUnavailable
    case requestFailed(status: Int, body: String)
    case requestFailedWithoutDetail(status: Int)
    case nonHTTPResponse
    case emptyResponse
    case reasoningLeaked(model: String, characters: Int)

    // These reach the user verbatim — on the pill and in the settings panel — so none of them may
    // fall back to the synthesised enum description the way `"\(error)"` would.
    var description: String {
        switch self {
        case let .missingKey(name):
            "\(name) is not set. Add it to ~/.config/sotto/.env."
        case .backendUnavailable:
            "the cleanup backend is unreachable"
        case let .requestFailed(status, body):
            "cleanup request failed (HTTP \(status)): \(body)"
        case let .requestFailedWithoutDetail(status):
            "cleanup request failed (HTTP \(status))"
        case .nonHTTPResponse:
            "the cleanup backend did not return an HTTP response"
        case .emptyResponse:
            "the cleanup backend returned nothing"
        case let .reasoningLeaked(model, characters):
            """
            model '\(model)' leaked reasoning into its output \
            (\(characters.formatted(.number.locale(Locale(identifier: "en_US")))) characters). \
            Pick a different model.
            """
        }
    }
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

    /// URLSession's 60 s default is an idle timeout, and `stream: false` means Ollama sends nothing
    /// until it has finished — so a model that reasons for 64 s presents as a stalled connection
    /// rather than a slow model. Bounding it at 20 s keeps that misreading short: past this the job
    /// degrades to a raw paste, which is the sanctioned degradation, instead of hanging for a minute.
    static let timeout: TimeInterval = 20

    static func makeRequest(json: Data, endpoint: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = json
        request.timeoutInterval = timeout
        return request
    }

    static func post(json: Data, to endpoint: URL, headers: [String: String]) async throws -> Data {
        try await send(makeRequest(json: json, endpoint: endpoint, headers: headers))
    }

    static func get(_ endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return try await send(request)
    }

    // `post` and `get` only differ in the request they build; every failure they can hit —
    // unreachable host, non-HTTP response, non-200 status — is classified identically here.
    private static func send(_ request: URLRequest) async throws -> Data {
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
