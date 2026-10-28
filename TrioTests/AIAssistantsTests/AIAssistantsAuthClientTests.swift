import AuthenticationServices
import Foundation
import Testing

@testable import Trio

@Suite("AI Assistants sign-in client", .serialized) struct AIAssistantsAuthClientTests {
    static let host = "t.example.com"
    let baseURL = URL(string: "https://t.example.com")!
    let now = Date(timeIntervalSince1970: 1_000_000)
    let pkce = PKCE(
        verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    )
    let credential = AppleCredential(identityToken: "id-tok", rawNonce: "raw-n", givenName: "Ann", familyName: "Lee")

    static let tokenResponse =
        #"{"access_token":"a","token_type":"Bearer","expires_in":3600,"expires_at":0,"refresh_token":"r","scope":"device offline_access"}"#

    func makeClient() -> AIAssistantsAuthClient {
        let now = self.now
        return AIAssistantsAuthClient(
            session: AIAssistantsAuthClient.makeSession(protocolClasses: [AIStubURLProtocol.self]),
            now: { now }
        )
    }

    func stub(_ handler: AIStubURLProtocol.Handler?) {
        AIStubURLProtocol.setHandler(for: Self.host, handler)
    }

    @Test("Session never stores or sends cookies") func sessionNeverStoresOrSendsCookies() {
        let configuration = AIAssistantsAuthClient.makeSession().configuration
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
    }

    @Test("Sign-in posts the Apple identity token, nonce and name") func createSessionPostsAppleIdToken() async throws {
        var captured: (URLRequest, Data?)?
        stub { request, body in
            captured = (request, body)
            return (200, Data(#"{"redirect":false,"token":"sess","user":{"id":"u1"}}"#.utf8))
        }
        let session = try await makeClient().createSession(credential, baseURL: baseURL)
        #expect(session.token == "sess")
        let (request, body) = try #require(captured)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth/sign-in/social")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(body?.jsonObject)
        #expect(json["provider"] as? String == "apple")
        let idToken = try #require(json["idToken"] as? [String: Any])
        #expect(idToken["token"] as? String == "id-tok")
        #expect(idToken["nonce"] as? String == "raw-n")
        let name = (idToken["user"] as? [String: Any])?["name"] as? [String: String]
        #expect(name == ["firstName": "Ann", "lastName": "Lee"])
    }

    @Test("Sign-in leaves out the user when Apple returned no name") func createSessionWithoutNameHasNoUser() async throws {
        var body: Data?
        stub { _, sent in
            body = sent
            return (200, Data(#"{"redirect":false,"token":"sess"}"#.utf8))
        }
        let anonymous = AppleCredential(identityToken: "id-tok", rawNonce: "raw-n", givenName: nil, familyName: nil)
        _ = try await makeClient().createSession(anonymous, baseURL: baseURL)
        let idToken = try #require(body?.jsonObject?["idToken"] as? [String: Any])
        #expect(idToken["user"] == nil)
    }

    @Test("Sign-in reads the account's email and name") func createSessionReadsAccount() async throws {
        stub { _, _ in
            (
                200,
                Data(
                    #"{"redirect":false,"token":"sess","user":{"id":"u1","email":"ann@example.com","name":"Ann Lee","emailVerified":true}}"#
                        .utf8
                )
            )
        }
        let session = try await makeClient().createSession(credential, baseURL: baseURL)
        #expect(session.token == "sess")
        #expect(session.account == AIAssistantsAccount(email: "ann@example.com", name: "Ann Lee"))
    }

    @Test("A missing, empty or malformed user still signs in") func createSessionToleratesOddUsers() async throws {
        let cases: [(String, AIAssistantsAccount?)] = [
            (#"{"redirect":false,"token":"sess"}"#, nil),
            (#"{"redirect":false,"token":"sess","user":null}"#, nil),
            (#"{"redirect":false,"token":"sess","user":{"id":"u1","email":"","name":"  "}}"#, nil),
            (#"{"redirect":false,"token":"sess","user":{"id":"u1","email":42,"name":"Ann"}}"#, nil),
            (
                #"{"redirect":false,"token":"sess","user":{"id":"u1","email":" ann@example.com ","name":""}}"#,
                AIAssistantsAccount(email: "ann@example.com", name: nil)
            )
        ]
        for (body, expected) in cases {
            stub { _, _ in (200, Data(body.utf8)) }
            let session = try await makeClient().createSession(credential, baseURL: baseURL)
            #expect(session.token == "sess")
            #expect(session.account == expected, "\(body)")
        }
    }

    @Test("A 403 not_invited maps to notInvited") func createSessionNotInvitedMapsToNotInvited() async {
        stub { _, _ in (403, Data(#"{"code":"not_invited","message":"This Apple ID isn't on the invite list."}"#.utf8)) }
        await #expect(throws: AIAssistantsAuthError.notInvited) {
            try await makeClient().createSession(credential, baseURL: baseURL)
        }
    }

    @Test("Other HTTP errors map to http(status)") func createSessionOtherErrorMapsToHttp() async {
        stub { _, _ in (500, Data(#"{"code":"oops"}"#.utf8)) }
        await #expect(throws: AIAssistantsAuthError.http(500)) {
            try await makeClient().createSession(credential, baseURL: baseURL)
        }
    }

    @Test("A URLError maps to network") func urlErrorMapsToNetwork() async {
        stub { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: AIAssistantsAuthError.network) {
            try await makeClient().createSession(credential, baseURL: baseURL)
        }
    }

    @Test("An unknown host or a failed connection maps to unreachable, not offline") func hostErrorsMapToUnreachable() async {
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .secureConnectionFailed, .unsupportedURL] {
            stub { _, _ in throw URLError(code) }
            await #expect(throws: AIAssistantsAuthError.unreachable) {
                try await makeClient().createSession(credential, baseURL: baseURL)
            }
        }
    }

    @Test("Authorize URL has the contract's parameters") func authorizeURLHasContractParameters() throws {
        let url = makeClient().authorizeURL(baseURL: baseURL, pkce: pkce, state: "s1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == Self.host)
        #expect(components.path == "/api/auth/oauth2/authorize")
        #expect(components.queryItems?.dict == [
            "response_type": "code",
            "client_id": "trio-ios",
            "redirect_uri": "triomcp://oauth-callback",
            "scope": "device offline_access",
            "resource": "https://t.example.com/api/v1",
            "state": "s1",
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "prompt": "none"
        ])
    }

    @Test("Authorize sends the session as a bearer token and reads the code") func authorizeSendsBearerAndAcceptJSONAndReadsCode(
    ) async throws {
        var captured: URLRequest?
        stub { request, _ in
            captured = request
            return (
                200,
                Data(
                    #"{"redirect":true,"url":"triomcp://oauth-callback?code=c1&state=s1&iss=https%3A%2F%2Ft.example.com%2Fapi%2Fauth"}"#
                        .utf8
                )
            )
        }
        let code = try await makeClient().authorize(sessionToken: "sess", pkce: pkce, state: "s1", baseURL: baseURL)
        #expect(code == "c1")
        let request = try #require(captured)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/auth/oauth2/authorize")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sess")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("A callback with another state is rejected") func callbackStateMismatchThrows() {
        #expect(throws: AIAssistantsAuthError.stateMismatch) {
            try makeClient().code(fromCallback: URL(string: "triomcp://oauth-callback?code=c&state=other")!, expectedState: "s1")
        }
    }

    @Test("A callback with an error carries it") func callbackWithErrorThrowsMissingCode() {
        #expect(throws: AIAssistantsAuthError.missingCode("login_required")) {
            try makeClient().code(
                fromCallback: URL(string: "triomcp://oauth-callback?error=login_required&state=s1")!,
                expectedState: "s1"
            )
        }
    }

    @Test("Code exchange posts the form and parses the tokens") func exchangePostsFormAndParsesTokens() async throws {
        var captured: (URLRequest, Data?)?
        stub { request, body in
            captured = (request, body)
            return (200, Data(Self.tokenResponse.utf8))
        }
        let tokens = try await makeClient().exchange(code: "c1", pkce: pkce, baseURL: baseURL)
        #expect(tokens == AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3540)))
        let (request, body) = try #require(captured)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth/oauth2/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(body?.formFields == [
            "grant_type": "authorization_code",
            "code": "c1",
            "code_verifier": pkce.verifier,
            "client_id": "trio-ios",
            "redirect_uri": "triomcp://oauth-callback",
            "resource": "https://t.example.com/api/v1"
        ])
    }

    @Test(
        "Refresh sends the resource, and invalid_grant maps to invalidGrant"
    ) func refreshSendsResourceAndInvalidGrantMapsToInvalidGrant() async throws {
        var fields: [String: String]?
        stub { _, body in
            fields = body?.formFields
            return (400, Data(#"{"error":"invalid_grant","error_description":"revoked"}"#.utf8))
        }
        let old = AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now)
        await #expect(throws: AIAssistantsAuthError.invalidGrant) {
            try await makeClient().refresh(old, baseURL: baseURL)
        }
        #expect(fields == [
            "grant_type": "refresh_token",
            "refresh_token": "r",
            "client_id": "trio-ios",
            "resource": "https://t.example.com/api/v1"
        ])
    }

    @Test("Refresh returns the rotated tokens") func refreshReturnsRotatedTokens() async throws {
        stub { _, _ in
            (200, Data(#"{"access_token":"a2","token_type":"Bearer","expires_in":3600,"refresh_token":"r2"}"#.utf8))
        }
        let old = AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now)
        let tokens = try await makeClient().refresh(old, baseURL: baseURL)
        #expect(tokens == AIAssistantsTokens(accessToken: "a2", refreshToken: "r2", expiresAt: now.addingTimeInterval(3540)))
    }

    @Test("Sign-in runs the contract steps in order and signs out") func signInRunsContractStepsInOrderAndSignsOut() async throws {
        var paths: [String] = []
        var signOutAuthorization: String?
        stub { request, _ in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/auth/sign-in/social":
                return (
                    200,
                    Data(#"{"redirect":false,"token":"sess","user":{"id":"u1","email":"ann@example.com","name":"Ann Lee"}}"#.utf8)
                )
            case "/api/auth/oauth2/authorize":
                let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.dict["state"] ?? ""
                return (200, Data(#"{"redirect":true,"url":"triomcp://oauth-callback?code=c1&state=\#(state)"}"#.utf8))
            case "/api/auth/oauth2/token":
                return (200, Data(Self.tokenResponse.utf8))
            default:
                signOutAuthorization = request.value(forHTTPHeaderField: "Authorization")
                return (200, Data(#"{"success":true}"#.utf8))
            }
        }
        let result = try await makeClient().signIn(with: credential, baseURL: baseURL)
        #expect(
            paths ==
                ["/api/auth/sign-in/social", "/api/auth/oauth2/authorize", "/api/auth/oauth2/token", "/api/auth/sign-out"]
        )
        #expect(signOutAuthorization == "Bearer sess")
        #expect(result.tokens == AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3540)))
        #expect(result.account == AIAssistantsAccount(email: "ann@example.com", name: "Ann Lee"))
    }

    @Test("Sign-in still succeeds when sign-out fails") func signInStillSucceedsWhenSignOutFails() async throws {
        stub { request, _ in
            switch request.url?.path {
            case "/api/auth/sign-in/social":
                return (200, Data(#"{"redirect":false,"token":"sess"}"#.utf8))
            case "/api/auth/oauth2/authorize":
                let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.dict["state"] ?? ""
                return (200, Data(#"{"redirect":true,"url":"triomcp://oauth-callback?code=c1&state=\#(state)"}"#.utf8))
            case "/api/auth/oauth2/token":
                return (200, Data(Self.tokenResponse.utf8))
            default:
                return (500, Data())
            }
        }
        let result = try await makeClient().signIn(with: credential, baseURL: baseURL)
        #expect(result.tokens.accessToken == "a")
    }

    @Test("Cancelling the Apple sheet maps to cancelled") func canceledAppleMapsToCancelled() {
        #expect(AIAssistantsAuthClient.mapAppleError(ASAuthorizationError(.canceled)) == .cancelled)
        #expect(AIAssistantsAuthClient.mapAppleError(ASAuthorizationError(.failed)) == .appleFailed)
    }
}
