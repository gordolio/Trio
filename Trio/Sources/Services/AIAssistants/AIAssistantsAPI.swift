import Foundation

/// This phone, as registered with the service (`PUT /api/v1/device`).
struct DeviceRegistration: Codable, Equatable {
    let apnsToken: String
    let bundleId: String
    let apnsEnvironment: String
    let appVersion: String
}

enum AIAssistantsAPIError: Error, Equatable {
    case notLinked
    /// The refresh token was revoked or expired; Trio has to sign in again.
    case signedOut
    /// The status and the contract's `error` code.
    case http(Int, String?)
    case network
}

protocol AIAssistantsAPIClient: AnyObject {
    func putDevice(_ device: DeviceRegistration) async throws
    func deleteDevice() async throws
    func putStatus(_ snapshot: StatusSnapshot) async throws
}

/// The device API (`BASE/api/v1`), with the stored `trio-ios` access token. Refreshes the
/// token when it has expired, and once more on a 401; a refused refresh signs Trio out.
final class AIAssistantsAPI: AIAssistantsAPIClient {
    private let store: AIAssistantsTokenStore
    private let auth: AIAssistantsAuthClient
    private let session: URLSession
    private let now: () -> Date

    init(
        store: AIAssistantsTokenStore,
        auth: AIAssistantsAuthClient,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.auth = auth
        self.session = session
        self.now = now
    }

    func putDevice(_ device: DeviceRegistration) async throws {
        try await send("PUT", "api/v1/device", body: JSONEncoder().encode(device))
    }

    func deleteDevice() async throws {
        try await send("DELETE", "api/v1/device", body: nil)
    }

    func putStatus(_ snapshot: StatusSnapshot) async throws {
        try await send("PUT", "api/v1/status", body: StatusSnapshot.makeEncoder().encode(snapshot))
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws {
        guard let baseURL = store.baseURL, var tokens = store.tokens else {
            throw AIAssistantsAPIError.notLinked
        }
        if tokens.expiresAt <= now() {
            tokens = try await refresh(tokens, baseURL: baseURL)
        }
        var (status, data) = try await perform(method, path, body: body, accessToken: tokens.accessToken, baseURL: baseURL)
        if status == 401 {
            tokens = try await refresh(tokens, baseURL: baseURL)
            (status, data) = try await perform(method, path, body: body, accessToken: tokens.accessToken, baseURL: baseURL)
            if status == 401 {
                store.tokens = nil
                throw AIAssistantsAPIError.signedOut
            }
        }
        guard (200 ..< 300).contains(status) else {
            throw AIAssistantsAPIError.http(status, (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
        }
    }

    private func refresh(_ tokens: AIAssistantsTokens, baseURL: URL) async throws -> AIAssistantsTokens {
        do {
            let fresh = try await auth.refresh(tokens, baseURL: baseURL)
            store.tokens = fresh
            return fresh
        } catch AIAssistantsAuthError.invalidGrant {
            store.tokens = nil
            throw AIAssistantsAPIError.signedOut
        } catch AIAssistantsAuthError.network, AIAssistantsAuthError.unreachable {
            throw AIAssistantsAPIError.network
        } catch let AIAssistantsAuthError.http(status) {
            throw AIAssistantsAPIError.http(status, nil)
        }
    }

    private func perform(
        _ method: String,
        _ path: String,
        body: Data?,
        accessToken: String,
        baseURL: URL
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AIAssistantsAPIError.network
            }
            return (response.statusCode, data)
        } catch is URLError {
            throw AIAssistantsAPIError.network
        }
    }
}

private struct ErrorBody: Decodable {
    let error: String
}
