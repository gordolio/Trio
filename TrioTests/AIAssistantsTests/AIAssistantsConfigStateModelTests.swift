import AuthenticationServices
import Combine
import Foundation
import Testing

@testable import Trio

final class FakeAIAssistantsService: AIAssistantsService {
    let state = CurrentValueSubject<AIAssistantsLinkState, Never>(.notLinked)
    let account = CurrentValueSubject<AIAssistantsAccount?, Never>(nil)
    private(set) var completedLinks: [(URL, AIAssistantsTokens, AIAssistantsAccount?)] = []
    private(set) var unlinkCount = 0
    /// What `unlink()` returns: whether the service deleted the device.
    var unlinkResult = true
    /// When set, `unlink()` waits for it to open.
    var unlinkGate: UploadGate?

    func completeLink(baseURL: URL, tokens: AIAssistantsTokens, account: AIAssistantsAccount?) async {
        completedLinks.append((baseURL, tokens, account))
    }

    func unlink() async -> Bool {
        unlinkCount += 1
        if let unlinkGate { await unlinkGate.wait() }
        return unlinkResult
    }

    func uploadNow() async {}
}

@Suite("AI Assistants settings state model", .serialized) @MainActor struct AIAssistantsConfigStateModelTests {
    static let host = "sm.example.com"
    let service = FakeAIAssistantsService()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let credential = AppleCredential(identityToken: "id-tok", rawNonce: "raw-n", givenName: nil, familyName: nil)

    func makeState(serviceURL: URL? = URL(string: "https://sm.example.com")) -> AIAssistantsConfig.StateModel {
        let state = AIAssistantsConfig.StateModel()
        state.service = service
        let now = self.now
        state.authClient = AIAssistantsAuthClient(
            session: AIAssistantsAuthClient.makeSession(protocolClasses: [StubURLProtocol.self]),
            now: { now }
        )
        state.serviceURL = serviceURL
        return state
    }

    func stub(_ handler: StubURLProtocol.Handler?) {
        StubURLProtocol.setHandler(for: Self.host, handler)
    }

    @Test("A build without a service shows a message and makes no request") func unconfiguredBuildShowsMessageAndMakesNoRequest(
    ) async {
        var requests = 0
        stub { _, _ in
            requests += 1
            return (500, Data())
        }
        let state = makeState(serviceURL: nil)
        await state.signIn(credential: credential)
        #expect(state.errorMessage == "This build isn't set up for AI Assistants.")
        #expect(state.isSigningIn == false)
        #expect(requests == 0)
        #expect(service.completedLinks.isEmpty)
    }

    @Test("The service address is https plus the build's host") func serviceURLComesFromTheBuildSetting() {
        let url = AIAssistantsConfig.StateModel.serviceURL(fromBuildSetting:)
        #expect(url("trio-rc.example.com") == URL(string: "https://trio-rc.example.com"))
        #expect(url(" trio-rc.example.com/ ") == URL(string: "https://trio-rc.example.com"))
        #expect(url("trio-rc.example.com:8443") == URL(string: "https://trio-rc.example.com:8443"))
        #expect(url("https://trio-rc.example.com") == URL(string: "https://trio-rc.example.com"))
        for unset in [nil, "", "  ", "$(AI_ASSISTANTS_SERVICE_HOST)", "http://trio-rc.example.com", "https://"] {
            #expect(url(unset) == nil)
        }
    }

    @Test("The app's Info.plist passes the build setting through") func infoPlistDeclaresServiceHost() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "AIAssistantsServiceHost") is String)
    }

    @Test(
        "Cancelling the Apple sheet changes nothing and shows no message"
    ) func cancelledAppleSheetLeavesStateUnchangedWithoutMessage() {
        let state = makeState()
        state.fail(with: ASAuthorizationError(.canceled))
        #expect(state.errorMessage == nil)
        #expect(state.isSigningIn == false)
    }

    @Test("Another Apple error asks to try again") func otherAppleErrorShowsTryAgain() {
        let state = makeState()
        state.fail(with: ASAuthorizationError(.failed))
        #expect(state.errorMessage == "Sign in with Apple didn't finish. Try again.")
    }

    @Test("An uninvited Apple ID shows the invite-list message") func notInvitedShowsInviteListMessage() async {
        stub { _, _ in (403, Data(#"{"code":"not_invited","message":"This Apple ID isn't on the invite list."}"#.utf8)) }
        let state = makeState()
        await state.signIn(credential: credential)
        #expect(state.errorMessage == "This Apple ID isn't on the invite list.")
        #expect(state.isSigningIn == false)
        #expect(service.completedLinks.isEmpty)
    }

    @Test("Being offline says so") func networkErrorShowsOffline() async {
        stub { _, _ in throw URLError(.notConnectedToInternet) }
        let state = makeState()
        await state.signIn(credential: credential)
        #expect(state.errorMessage == "Couldn't sign in (offline). Try again.")
    }

    @Test("An unreachable host names it") func unreachableHostNamesIt() async {
        stub { _, _ in throw URLError(.cannotFindHost) }
        let state = makeState()
        await state.signIn(credential: credential)
        #expect(state.errorMessage == "Couldn't reach sm.example.com. Try again.")
    }

    @Test("A server error shows its status") func httpErrorShowsStatus() async {
        stub { _, _ in (502, Data()) }
        let state = makeState()
        await state.signIn(credential: credential)
        #expect(state.errorMessage == "Couldn't sign in (error 502). Try again.")
    }

    @Test("A successful sign-in completes the link with the tokens and account") func successfulSignInCallsCompleteLinkWithTokens(
    ) async throws {
        stub { request, _ in
            switch request.url?.path {
            case "/api/auth/sign-in/social":
                return (
                    200,
                    Data(#"{"redirect":false,"token":"sess","user":{"id":"u1","email":"ann@example.com","name":"Ann Lee"}}"#.utf8)
                )
            case "/api/auth/oauth2/authorize":
                let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.dict["state"] ?? ""
                return (200, Data(#"{"redirect":true,"url":"triomcp://oauth-callback?code=c1&state=\#(state)"}"#.utf8))
            case "/api/auth/oauth2/token":
                return (
                    200,
                    Data(
                        #"{"access_token":"a","token_type":"Bearer","expires_in":3600,"refresh_token":"r","scope":"device offline_access"}"#
                            .utf8
                    )
                )
            default:
                return (200, Data("{}".utf8))
            }
        }
        let state = makeState()
        state.errorMessage = "old"
        await state.signIn(credential: credential)
        let (baseURL, tokens, account) = try #require(service.completedLinks.first)
        #expect(baseURL == URL(string: "https://sm.example.com"))
        #expect(tokens == AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3540)))
        #expect(account == AIAssistantsAccount(email: "ann@example.com", name: "Ann Lee"))
        #expect(state.isSigningIn == false)
        #expect(state.errorMessage == nil)
    }

    @Test("prepare asks for name and email and sends the hashed nonce") func prepareSetsScopesAndHashedNonce() throws {
        let state = makeState()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        state.prepare(request)
        #expect(request.requestedScopes == [.fullName, .email])
        let credential = try #require(state.appleCredential(identityToken: Data("tok".utf8), givenName: "Ann", familyName: "Lee"))
        #expect(
            credential ==
                AppleCredential(identityToken: "tok", rawNonce: credential.rawNonce, givenName: "Ann", familyName: "Lee")
        )
        #expect(request.nonce == AppleNonce.sha256Hex(credential.rawNonce))
    }

    @Test("Signing out unlinks through the service") func signOutUnlinksThroughService() async {
        let state = makeState()
        state.errorMessage = "old"
        await state.signOut()
        #expect(service.unlinkCount == 1)
        #expect(state.errorMessage == nil)
    }

    @Test("Signing out while the service can't be reached says the status may still be visible") func signOutOfflineSaysSo() async {
        service.unlinkResult = false
        let state = makeState()
        await state.signOut()
        #expect(service.unlinkCount == 1)
        #expect(
            state.errorMessage ==
                "Signed out, but Trio couldn't reach the service, so assistants may still see your last status. Sign in and sign out again when you're online."
        )
    }

    @Test("Signing out shows progress until the service is done") func signOutShowsProgressUntilDone() async {
        let gate = UploadGate()
        service.unlinkGate = gate
        let state = makeState()
        let signOut = Task { await state.signOut() }
        #expect(await eventuallyTrue { state.isSigningOut })
        gate.open()
        await signOut.value
        #expect(state.isSigningOut == false)
    }
}
