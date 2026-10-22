import Combine
import Foundation

/// The Apple Watch app's own push registration; the service pushes a request to it directly.
struct WatchRegistration: Codable, Equatable {
    let apnsToken: String
    let bundleId: String
    let apnsEnvironment: String
}

/// This phone, as registered with the service (`PUT /api/v1/device`).
struct DeviceRegistration: Codable, Equatable {
    let apnsToken: String
    let bundleId: String
    let apnsEnvironment: String
    let appVersion: String
    /// `nil` until the watch app has sent its push token.
    let watch: WatchRegistration?
    /// `AIWakePushType`'s raw value. `nil` leaves it to the service, which wakes Trio with a passive push.
    let wakePushType: String?

    init(
        apnsToken: String,
        bundleId: String,
        apnsEnvironment: String,
        appVersion: String,
        watch: WatchRegistration? = nil,
        wakePushType: String? = nil
    ) {
        self.apnsToken = apnsToken
        self.bundleId = bundleId
        self.apnsEnvironment = apnsEnvironment
        self.appVersion = appVersion
        self.watch = watch
        self.wakePushType = wakePushType
    }
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
    /// The service address, each time a call finds Trio signed out of it. The uploads, the check-ins and the
    /// state reports all call the service, and any of them may be the first to find out.
    var signedOut: AnyPublisher<URL, Never> { get }
    func putDevice(_ device: DeviceRegistration) async throws
    func deleteDevice() async throws
    func putStatus(_ snapshot: StatusSnapshot) async throws
    func getInbox() async throws -> AIInbox
    func putRequestState(id: String, _ body: AIRequestStateBody) async throws
}

/// The device API (`BASE/api/v1`), with the stored `trio-ios` access token. Refreshes the
/// token when it has expired, and once more on a 401; a refused refresh signs Trio out.
final class AIAssistantsAPI: AIAssistantsAPIClient {
    private let store: AIAssistantsTokenStore
    private let auth: AIAssistantsAuthClient
    private let session: URLSession
    private let now: () -> Date
    private let signedOutSubject = PassthroughSubject<URL, Never>()

    private let refreshLock = NSLock()
    /// The refresh in flight, which every call that needs one waits for.
    private var refreshing: Task<AIAssistantsTokens, Error>?

    var signedOut: AnyPublisher<URL, Never> { signedOutSubject.eraseToAnyPublisher() }

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

    func getInbox() async throws -> AIInbox {
        let data = try await send("GET", "api/v1/inbox", body: nil)
        return try AIInbox.decoder.decode(AIInbox.self, from: data)
    }

    func putRequestState(id: String, _ body: AIRequestStateBody) async throws {
        try await send("PUT", "api/v1/requests/\(id)/state", body: JSONEncoder().encode(body))
    }

    /// Returns the response body.
    @discardableResult private func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
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
                throw signOut(tokens, baseURL: baseURL)
            }
        }
        guard (200 ..< 300).contains(status) else {
            throw AIAssistantsAPIError.http(status, (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
        }
        return data
    }

    /// One refresh runs at a time, and every call that needs one waits for it: the service takes a refresh token
    /// once, and a second use revokes all of Trio's tokens. A call whose tokens were replaced since it read them
    /// gets the new ones without refreshing.
    private func refresh(_ tokens: AIAssistantsTokens, baseURL: URL) async throws -> AIAssistantsTokens {
        let shared = refreshLock.withLock { () -> Task<AIAssistantsTokens, Error>? in
            if let refreshing { return refreshing }
            guard store.tokens == tokens else { return nil }
            let task = Task {
                defer { self.refreshLock.withLock { self.refreshing = nil } }
                return try await self.refreshOnce(tokens, baseURL: baseURL)
            }
            refreshing = task
            return task
        }
        guard let shared else { return try storedTokens() }
        return try await shared.value
    }

    /// The result is stored only if the old tokens are still there. If Trio was unlinked or linked again
    /// meanwhile, it's dropped, and the call goes on with what is stored now.
    private func refreshOnce(_ tokens: AIAssistantsTokens, baseURL: URL) async throws -> AIAssistantsTokens {
        do {
            let fresh = try await auth.refresh(tokens, baseURL: baseURL)
            guard store.replaceTokens(tokens, with: fresh) else { return try storedTokens() }
            return fresh
        } catch AIAssistantsAuthError.invalidGrant {
            guard store.replaceTokens(tokens, with: nil) else { return try storedTokens() }
            signedOutSubject.send(baseURL)
            throw AIAssistantsAPIError.signedOut
        } catch AIAssistantsAuthError.network, AIAssistantsAuthError.unreachable {
            throw AIAssistantsAPIError.network
        } catch let AIAssistantsAuthError.http(status) {
            throw AIAssistantsAPIError.http(status, nil)
        }
    }

    /// Forgets the tokens the service refused and tells `signedOut`, unless another call got there first or a new
    /// link stored other tokens meanwhile.
    private func signOut(_ tokens: AIAssistantsTokens, baseURL: URL) -> AIAssistantsAPIError {
        if store.replaceTokens(tokens, with: nil) {
            signedOutSubject.send(baseURL)
        }
        return .signedOut
    }

    /// The tokens stored now, for a call whose own were replaced.
    private func storedTokens() throws -> AIAssistantsTokens {
        if let tokens = store.tokens { return tokens }
        throw store.baseURL == nil ? AIAssistantsAPIError.notLinked : .signedOut
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
