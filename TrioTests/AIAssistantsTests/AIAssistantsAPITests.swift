import Combine
import Foundation
import Security
import Testing

@testable import Trio

/// The addresses the client said Trio was signed out of.
private final class SignedOutLog {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var subscription: AnyCancellable?

    var urls: [URL] { lock.withLock { recorded } }

    init(_ api: AIAssistantsAPI) {
        subscription = api.signedOut.sink { [weak self] url in
            guard let self else { return }
            self.lock.withLock { self.recorded.append(url) }
        }
    }
}

@Suite("AI Assistants device API client", .serialized) struct AIAssistantsAPITests {
    static let host = "api.example.com"
    let baseURL = URL(string: "https://api.example.com")!
    let now = Date(timeIntervalSince1970: 1_000_000)
    let keychain = InMemoryKeychain()
    let device = DeviceRegistration(
        apnsToken: String(repeating: "ab", count: 32),
        bundleId: "org.nightscout.TEAMID.trio",
        apnsEnvironment: "sandbox",
        appVersion: "1.0.2.12"
    )

    static let refreshed =
        #"{"access_token":"a2","token_type":"Bearer","expires_in":3600,"refresh_token":"r2","scope":"device offline_access"}"#

    func makeAPI(tokensExpireAt expiry: Date? = nil) -> (AIAssistantsAPI, AIAssistantsTokenStore) {
        let store = AIAssistantsTokenStore(keychain: keychain)
        store.baseURL = baseURL
        store.tokens = AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: expiry ?? now.addingTimeInterval(600))
        let session = AIAssistantsAuthClient.makeSession(protocolClasses: [StubURLProtocol.self])
        let now = self.now
        let api = AIAssistantsAPI(
            store: store,
            auth: AIAssistantsAuthClient(session: session, now: { now }),
            session: session,
            now: { now }
        )
        return (api, store)
    }

    func stub(_ handler: StubURLProtocol.Handler?) {
        StubURLProtocol.setHandler(for: Self.host, handler)
    }

    @Test("Token store round-trips and clear removes every key") func storeRoundTripsAndClearRemovesAllKeys() {
        let store = AIAssistantsTokenStore(keychain: keychain)
        #expect(store.baseURL == nil)
        #expect(store.tokens == nil)
        let tokens = AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now)
        store.baseURL = baseURL
        store.tokens = tokens
        #expect(AIAssistantsTokenStore(keychain: keychain).baseURL == baseURL)
        #expect(AIAssistantsTokenStore(keychain: keychain).tokens == tokens)
        store.tokens = nil
        #expect(keychain.storage["AIAssistants.tokens"] == nil)
        store.tokens = tokens
        keychain.setData(Data("x".utf8), forKey: "AIAssistants.lastDevice")
        store.clear()
        #expect(keychain.storage.isEmpty)
    }

    @Test("The last registered device round-trips, and nil removes it") func lastDeviceRoundTrips() {
        let store = AIAssistantsTokenStore(keychain: keychain)
        #expect(store.lastDevice == nil)
        store.lastDevice = device
        #expect(AIAssistantsTokenStore(keychain: keychain).lastDevice == device)
        store.lastDevice = nil
        #expect(keychain.storage["AIAssistants.lastDevice"] == nil)
    }

    @Test("The app's token store keeps items on this device only") func deviceOnlyStoreNeverSyncs() throws {
        let serviceName = "TrioTests.AIAssistants.\(UUID().uuidString)"
        let store = AIAssistantsTokenStore.deviceOnly(serviceName: serviceName)
        store.tokens = AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Data("AIAssistants.tokens".utf8),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1)
        #expect((items.first?[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
        #expect(
            items
                .first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        store.clear()
        #expect(store.tokens == nil)
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
    }

    @Test("Refresh that can't reach the server maps to network") func refreshUnreachableMapsToNetwork() async {
        stub { _, _ in throw URLError(.cannotFindHost) }
        let (api, store) = makeAPI(tokensExpireAt: now)
        await #expect(throws: AIAssistantsAPIError.network) {
            try await api.putDevice(device)
        }
        #expect(store.tokens != nil)
    }

    @Test("PUT device sends the bearer token and JSON") func putDeviceSendsBearerAndJSON() async throws {
        var captured: (URLRequest, Data?)?
        stub { request, body in
            captured = (request, body)
            return (204, Data())
        }
        let (api, _) = makeAPI()
        try await api.putDevice(device)
        let (request, body) = try #require(captured)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/v1/device")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONDecoder().decode(DeviceRegistration.self, from: #require(body)) == device)
    }

    @Test("PUT status sends the bearer token and the snapshot as JSON") func putStatusSendsBearerAndJSON() async throws {
        var captured: (URLRequest, Data?)?
        stub { request, body in
            captured = (request, body)
            return (204, Data())
        }
        let (api, _) = makeAPI()
        try await api.putStatus(.fixture())
        let (request, body) = try #require(captured)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/v1/status")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try StatusSnapshot.testDecoder().decode(StatusSnapshot.self, from: #require(body)) == .fixture())
    }

    @Test("PUT device leaves out the watch and the wake-up push type when they are nil") func deviceJSONLeavesOutNilFields(
    ) async throws {
        var captured: Data?
        stub { _, body in
            captured = body
            return (204, Data())
        }
        let (api, _) = makeAPI()
        try await api.putDevice(device)
        let object = try #require(captured?.jsonObject)
        #expect(Set(object.keys) == ["apnsToken", "bundleId", "apnsEnvironment", "appVersion"])
    }

    @Test("PUT device sends the watch and the wake-up push type when set") func deviceJSONIncludesWatchAndWakePushType(
    ) async throws {
        var captured: Data?
        stub { _, body in
            captured = body
            return (204, Data())
        }
        let (api, _) = makeAPI()
        let withWatch = DeviceRegistration(
            apnsToken: device.apnsToken,
            bundleId: device.bundleId,
            apnsEnvironment: device.apnsEnvironment,
            appVersion: device.appVersion,
            watch: WatchRegistration(
                apnsToken: String(repeating: "cd", count: 32),
                bundleId: "org.nightscout.TEAMID.trio.watchkitapp",
                apnsEnvironment: "sandbox"
            ),
            wakePushType: "timeSensitive"
        )
        try await api.putDevice(withWatch)
        let object = try #require(captured?.jsonObject)
        #expect(Set(object.keys) == ["apnsToken", "bundleId", "apnsEnvironment", "appVersion", "watch", "wakePushType"])
        #expect(object["wakePushType"] as? String == "timeSensitive")
        #expect(object["watch"] as? [String: String] == [
            "apnsToken": String(repeating: "cd", count: 32),
            "bundleId": "org.nightscout.TEAMID.trio.watchkitapp",
            "apnsEnvironment": "sandbox"
        ])
        #expect(try JSONDecoder().decode(DeviceRegistration.self, from: #require(captured)) == withWatch)
    }

    @Test("A device stored before the watch and push type existed still decodes") func olderStoredDeviceDecodes() throws {
        let json = #"{"apnsToken":"ab","bundleId":"b","apnsEnvironment":"sandbox","appVersion":"1.0"}"#
        let decoded = try JSONDecoder().decode(DeviceRegistration.self, from: Data(json.utf8))
        #expect(decoded.watch == nil && decoded.wakePushType == nil)
    }

    @Test("GET inbox sends the bearer token and decodes the body") func getInboxSendsBearerAndDecodes() async throws {
        var captured: (URLRequest, Data?)?
        let json =
            #"{"requests":[{"id":"r1","kind":"meal","source":"ChatGPT","createdAt":"2026-10-19T15:04:05.123Z","expiresAt":"2026-10-19T15:09:05.123Z","withdrawn":false,"meal":{"description":"pizza","carbs":20,"fat":10,"protein":8}}],"answers":[]}"#
        stub { request, body in
            captured = (request, body)
            return (200, Data(json.utf8))
        }
        let (api, _) = makeAPI()
        let inbox = try await api.getInbox()
        let (request, body) = try #require(captured)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/inbox")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a")
        #expect(body == nil)
        #expect(inbox.requests.map(\.id) == ["r1"])
        #expect(inbox.requests[0].meal?.carbs == 20)
        #expect(inbox.answers.isEmpty)
    }

    @Test("GET inbox fails when the body isn't an inbox") func getInboxRejectsAnotherBody() async {
        stub { _, _ in (200, Data(#"{"requests":"none"}"#.utf8)) }
        let (api, _) = makeAPI()
        await #expect(throws: DecodingError.self) {
            _ = try await api.getInbox()
        }
    }

    @Test("PUT request state sends the bearer token and the state as JSON") func putRequestStateSendsBearerAndJSON(
    ) async throws {
        var captured: (URLRequest, Data?)?
        stub { request, body in
            captured = (request, body)
            return (204, Data())
        }
        let (api, _) = makeAPI()
        try await api.putRequestState(id: "r1", AIRequestStateBody(.failed(reason: "over the limit", carbsLogged: false)))
        let (request, body) = try #require(captured)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/v1/requests/r1/state")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let object = try #require(body?.jsonObject)
        #expect(object["state"] as? String == "failed")
        #expect(object["reason"] as? String == "over the limit")
        #expect(object["carbsLogged"] as? Bool == false)
    }

    @Test("A 409 on a state report carries the contract's error code") func conflictMapsToHttpWithErrorCode() async {
        stub { _, _ in (409, Data(#"{"error":"conflict","message":"r1 is already final"}"#.utf8)) }
        let (api, _) = makeAPI()
        await #expect(throws: AIAssistantsAPIError.http(409, "conflict")) {
            try await api.putRequestState(id: "r1", AIRequestStateBody(.expired))
        }
    }

    @Test("A 404 on a state report carries the contract's error code") func notFoundMapsToHttpWithErrorCode() async {
        stub { _, _ in (404, Data(#"{"error":"not_found","message":"no such request"}"#.utf8)) }
        let (api, _) = makeAPI()
        await #expect(throws: AIAssistantsAPIError.http(404, "not_found")) {
            try await api.putRequestState(id: "r1", AIRequestStateBody(.withdrawn))
        }
    }

    @Test("A 401 on the inbox refreshes once and retries once") func inboxUnauthorizedRefreshesAndRetries() async throws {
        var paths: [String] = []
        stub { request, _ in
            paths.append(request.url?.path ?? "")
            if request.url?.path == "/api/auth/oauth2/token" {
                return (200, Data(Self.refreshed.utf8))
            }
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer a2"
            return authorized
                ? (200, Data(#"{"requests":[],"answers":[]}"#.utf8))
                : (401, Data(#"{"error":"invalid_token","message":"expired"}"#.utf8))
        }
        let (api, _) = makeAPI()
        let inbox = try await api.getInbox()
        #expect(paths == ["/api/v1/inbox", "/api/auth/oauth2/token", "/api/v1/inbox"])
        #expect(inbox.requests.isEmpty)
    }

    @Test("DELETE device sends the bearer token") func deleteDeviceSendsDelete() async throws {
        var captured: URLRequest?
        stub { request, _ in
            captured = request
            return (204, Data())
        }
        let (api, _) = makeAPI()
        try await api.deleteDevice()
        #expect(captured?.httpMethod == "DELETE")
        #expect(captured?.url?.path == "/api/v1/device")
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer a")
    }

    @Test("An expired access token is refreshed before the request") func refreshesExpiredTokenBeforeRequest() async throws {
        var deviceAuthorization: String?
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                return (200, Data(Self.refreshed.utf8))
            }
            deviceAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return (204, Data())
        }
        let (api, store) = makeAPI(tokensExpireAt: now)
        try await api.putDevice(device)
        #expect(deviceAuthorization == "Bearer a2")
        #expect(
            store
                .tokens == AIAssistantsTokens(accessToken: "a2", refreshToken: "r2", expiresAt: now.addingTimeInterval(3540))
        )
    }

    @Test("A 401 refreshes once and retries once") func unauthorizedThenRefreshThenRetrySucceeds() async throws {
        var paths: [String] = []
        stub { request, _ in
            paths.append(request.url?.path ?? "")
            if request.url?.path == "/api/auth/oauth2/token" {
                return (200, Data(Self.refreshed.utf8))
            }
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer a2"
            return authorized ? (204, Data()) : (401, Data(#"{"error":"invalid_token","message":"expired"}"#.utf8))
        }
        let (api, store) = makeAPI()
        try await api.putDevice(device)
        #expect(paths == ["/api/v1/device", "/api/auth/oauth2/token", "/api/v1/device"])
        #expect(store.tokens?.accessToken == "a2")
        #expect(store.tokens?.refreshToken == "r2")
    }

    @Test("A revoked refresh token clears the tokens and signs out") func revokedRefreshTokenClearsTokensAndThrowsSignedOut() async {
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return (401, Data(#"{"error":"invalid_token","message":"revoked"}"#.utf8))
        }
        let (api, store) = makeAPI()
        let signedOut = SignedOutLog(api)
        await #expect(throws: AIAssistantsAPIError.signedOut) {
            try await api.putDevice(device)
        }
        #expect(store.tokens == nil)
        #expect(store.baseURL == baseURL)
        #expect(signedOut.urls == [baseURL])
    }

    @Test("A second 401 after refreshing signs out") func retryStillUnauthorizedSignsOut() async {
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                return (200, Data(Self.refreshed.utf8))
            }
            return (401, Data(#"{"error":"invalid_token","message":"revoked"}"#.utf8))
        }
        let (api, store) = makeAPI()
        let signedOut = SignedOutLog(api)
        await #expect(throws: AIAssistantsAPIError.signedOut) {
            try await api.deleteDevice()
        }
        #expect(store.tokens == nil)
        #expect(signedOut.urls == [baseURL])
    }

    @Test("A refused refresh tells whoever listens, once") func refusedRefreshPublishesSignedOut() async {
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return (401, Data(#"{"error":"invalid_token","message":"revoked"}"#.utf8))
        }
        let (api, _) = makeAPI()
        let signedOut = SignedOutLog(api)
        await #expect(throws: AIAssistantsAPIError.signedOut) {
            _ = try await api.getInbox()
        }
        #expect(signedOut.urls == [baseURL])
        // Without tokens a later call isn't linked, and has nothing to tell.
        await #expect(throws: AIAssistantsAPIError.notLinked) {
            _ = try await api.getInbox()
        }
        #expect(signedOut.urls == [baseURL])
    }

    @Test("Calls that find the token expired at once share one refresh") func concurrentCallsShareOneRefresh() async throws {
        let refreshes = CallCounter()
        let freshCalls = CallCounter()
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                refreshes.record()
                // Long enough for the other call to find the token expired too.
                Thread.sleep(forTimeInterval: 0.2)
                return (200, Data(Self.refreshed.utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer a2" {
                freshCalls.record()
            }
            return (204, Data())
        }
        let (api, store) = makeAPI(tokensExpireAt: now)
        async let deviceSent: Void = api.putDevice(device)
        async let statusSent: Void = api.putStatus(.fixture())
        _ = try await (deviceSent, statusSent)
        // A refresh token works once: a second refresh with it would revoke Trio's tokens.
        #expect(refreshes.calls == 1)
        #expect(freshCalls.calls == 2)
        #expect(store.tokens?.refreshToken == "r2")
    }

    @Test("A 401 after another call refreshed retries with the new tokens") func unauthorizedAfterAnotherRefreshUsesNewTokens(
    ) async throws {
        let (api, store) = makeAPI()
        let refreshes = CallCounter()
        let newTokens = AIAssistantsTokens(accessToken: "a2", refreshToken: "r2", expiresAt: now.addingTimeInterval(3600))
        var authorizations: [String] = []
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                refreshes.record()
                return (200, Data(Self.refreshed.utf8))
            }
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            authorizations.append(authorization)
            guard authorization == "Bearer a2" else {
                // Another call refreshed while this one was on its way.
                store.tokens = newTokens
                return (401, Data(#"{"error":"invalid_token","message":"expired"}"#.utf8))
            }
            return (204, Data())
        }
        try await api.putDevice(device)
        #expect(refreshes.calls == 0)
        #expect(authorizations == ["Bearer a", "Bearer a2"])
        #expect(store.tokens == newTokens)
    }

    @Test("A refresh that finishes after unlinking stores nothing") func refreshAfterUnlinkStoresNothing() async {
        let (api, store) = makeAPI(tokensExpireAt: now)
        let signedOut = SignedOutLog(api)
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                // Trio is unlinked while the refresh is on its way.
                store.clear()
                return (200, Data(Self.refreshed.utf8))
            }
            Issue.record("no request expected after unlinking")
            return (204, Data())
        }
        await #expect(throws: AIAssistantsAPIError.notLinked) {
            try await api.putDevice(device)
        }
        #expect(store.tokens == nil)
        #expect(store.baseURL == nil)
        #expect(signedOut.urls.isEmpty)
    }

    @Test("A refused refresh after linking again keeps the new link") func refusedRefreshAfterRelinkKeepsNewTokens() async throws {
        let (api, store) = makeAPI(tokensExpireAt: now)
        let signedOut = SignedOutLog(api)
        let newTokens = AIAssistantsTokens(accessToken: "n", refreshToken: "rn", expiresAt: now.addingTimeInterval(3600))
        var authorization: String?
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                // Trio was linked again while the old link's refresh was on its way.
                store.tokens = newTokens
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (204, Data())
        }
        try await api.putDevice(device)
        #expect(authorization == "Bearer n")
        #expect(store.tokens == newTokens)
        #expect(signedOut.urls.isEmpty)
    }

    @Test("A URLError maps to network") func urlErrorMapsToNetwork() async {
        stub { _, _ in throw URLError(.notConnectedToInternet) }
        let (api, store) = makeAPI()
        await #expect(throws: AIAssistantsAPIError.network) {
            try await api.putDevice(device)
        }
        #expect(store.tokens != nil)
    }

    @Test("A 400 carries the contract's error code") func badRequestMapsToHttpWithErrorCode() async {
        stub { _, _ in (400, Data(#"{"error":"invalid_body","message":"apnsToken is too short"}"#.utf8)) }
        let (api, _) = makeAPI()
        await #expect(throws: AIAssistantsAPIError.http(400, "invalid_body")) {
            try await api.putDevice(device)
        }
    }

    @Test("Without a service address the client isn't linked") func notLinkedWhenNoBaseURL() async {
        stub { _, _ in
            Issue.record("no request expected")
            return (204, Data())
        }
        let (api, store) = makeAPI()
        store.baseURL = nil
        await #expect(throws: AIAssistantsAPIError.notLinked) {
            try await api.putDevice(device)
        }
    }
}
