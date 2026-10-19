import Foundation
import Security
import Testing

@testable import Trio

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
        await #expect(throws: AIAssistantsAPIError.signedOut) {
            try await api.putDevice(device)
        }
        #expect(store.tokens == nil)
        #expect(store.baseURL == baseURL)
    }

    @Test("A second 401 after refreshing signs out") func retryStillUnauthorizedSignsOut() async {
        stub { request, _ in
            if request.url?.path == "/api/auth/oauth2/token" {
                return (200, Data(Self.refreshed.utf8))
            }
            return (401, Data(#"{"error":"invalid_token","message":"revoked"}"#.utf8))
        }
        let (api, store) = makeAPI()
        await #expect(throws: AIAssistantsAPIError.signedOut) {
            try await api.deleteDevice()
        }
        #expect(store.tokens == nil)
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
