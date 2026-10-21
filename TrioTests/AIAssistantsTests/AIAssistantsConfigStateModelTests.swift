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

    // MARK: - Request preferences

    func freshStore() -> AIAssistantsPreferencesStore {
        AIAssistantsPreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test("A change on the screen is written to the store") func preferencesWriteThrough() {
        let store = freshStore()
        let state = makeState()
        state.preferencesStore = store
        state.subscribe()
        state.preferences.approvalStyle = .oneGesture
        state.preferences.phoneBackupDelay = 30
        state.preferences.wakePushType = .timeSensitive
        #expect(store.value.approvalStyle == .oneGesture)
        #expect(store.value.phoneBackupDelay == 30)
        #expect(store.value.wakePushType == .timeSensitive)
    }

    @Test("A change in the store reaches the screen") func storeChangesReachTheModel() async {
        let store = freshStore()
        let state = makeState()
        state.preferencesStore = store
        state.subscribe()
        store.value.answerRoute = .serviceOnly
        #expect(await eventuallyTrue { state.preferences.answerRoute == .serviceOnly })
    }

    @Test("The screen starts with what the store holds") func screenStartsWithTheStoredPreferences() {
        let store = freshStore()
        store.value = AIAssistantsPreferences(
            approvalStyle: .oneGesture,
            phoneBackupDelay: 60,
            answerRoute: .watchOnly,
            wakePushType: .background
        )
        let state = makeState()
        state.preferencesStore = store
        state.subscribe()
        #expect(state.preferences == store.value)
    }

    @Test(
        "A change on the screen is written once, and the store's update doesn't write it again"
    ) func preferencesWriteDoesNotEcho(
    ) async {
        let store = freshStore()
        let state = makeState()
        state.preferencesStore = store
        state.subscribe()
        var writes = 0
        let subscription = store.changes.dropFirst().sink { _ in writes += 1 }
        state.preferences.approvalStyle = .oneGesture
        await letDebouncePass()
        #expect(writes == 1)
        #expect(state.preferences.approvalStyle == .oneGesture)
        subscription.cancel()
    }

    @Test("Two quick changes on the screen settle on the last one") func quickChangesSettleOnTheLastOne() async {
        let store = freshStore()
        let state = makeState()
        state.preferencesStore = store
        state.subscribe()
        var writes = 0
        let subscription = store.changes.dropFirst().sink { _ in writes += 1 }
        state.preferences.wakePushType = .background
        state.preferences.wakePushType = .timeSensitive
        await letDebouncePass()
        #expect(writes == 2)
        #expect(state.preferences.wakePushType == .timeSensitive)
        #expect(store.value.wakePushType == .timeSensitive)
        subscription.cancel()
    }

    @Test("Without a store the screen keeps its own preferences") func preferencesWithoutAStoreStayOnTheScreen() async {
        let state = makeState()
        state.preferencesStore = nil
        state.subscribe()
        state.preferences.answerRoute = .watchOnly
        await letDebouncePass()
        #expect(state.preferences.answerRoute == .watchOnly)
    }

    @Test(
        "A test request hands Trio 10 g from the phone that lasts five minutes"
    ) func testRequestIsTenGramsAndLocal(
    ) async throws {
        let state = makeState()
        var received: [(AIMealRequest, AIRequestChannel)] = []
        state.receiveRequest = { received.append(($0, $1)) }
        #expect(state.canSendTestRequest)
        await state.sendTestRequest(.dryRun)
        let (request, channel) = try #require(received.first)
        #expect(received.count == 1)
        #expect(channel == .local)
        #expect(request.carbs == 10)
        #expect(request.fat == 0)
        #expect(request.protein == 0)
        #expect(!request.id.isEmpty)
        #expect(request.expiresAt.timeIntervalSince(request.createdAt) == 300)
        #expect(abs(request.createdAt.timeIntervalSinceNow) < 5)
    }

    @Test("The dry-run test request is marked as one, from \"Trio test\"") func dryRunTestRequestIsMarked() async throws {
        let state = makeState()
        var received: [AIMealRequest] = []
        state.receiveRequest = { request, _ in received.append(request) }
        await state.sendTestRequest(.dryRun)
        let request = try #require(received.first)
        #expect(request.testKind == .dryRun)
        #expect(request.source == "Trio test")
        #expect(request.description == "10 g carbs")
    }

    @Test("The real test request is marked as one, from \"Trio test\"") func realTestRequestIsMarked() async throws {
        let state = makeState()
        var received: [AIMealRequest] = []
        state.receiveRequest = { request, _ in received.append(request) }
        await state.sendTestRequest(.real)
        let request = try #require(received.first)
        #expect(request.testKind == .real)
        #expect(request.source == "Trio test")
        #expect(request.description == "10 g carbs")
        #expect(request.carbs == 10)
    }

    @Test("Each test request has its own ID") func testRequestsHaveDifferentIDs() async {
        let state = makeState()
        var ids: [String] = []
        state.receiveRequest = { request, _ in ids.append(request.id) }
        await state.sendTestRequest(.dryRun)
        await state.sendTestRequest(.real)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    @Test("Each test request sent counts once, for the confirmation") func testRequestsAreCounted() async {
        let state = makeState()
        state.receiveRequest = { _, _ in }
        #expect(state.testCount == 0)
        await state.sendTestRequest(.dryRun)
        #expect(state.testCount == 1)
        await state.sendTestRequest(.real)
        #expect(state.testCount == 2)
    }

    @Test("Without the request runtime the test request can't be sent") func testRequestNeedsTheRuntime() async {
        let state = makeState()
        state.receiveRequest = nil
        #expect(!state.canSendTestRequest)
        await state.sendTestRequest(.dryRun)
        await state.sendTestRequest(.real)
        #expect(state.testCount == 0)
    }

    // MARK: - A test request's result

    /// A state model whose test requests go to `receive`, which hears the outcomes sent on `outcomes`, and whose
    /// VoiceOver announcements land in `announced`.
    func makeTestingState(
        outcomes: PassthroughSubject<AIRequestOutcome, Never>,
        announced: TestBox<[String]>,
        receive: @escaping @MainActor(AIMealRequest) async -> Void
    ) -> AIAssistantsConfig.StateModel {
        let state = makeState()
        state.requestOutcomes = outcomes.eraseToAnyPublisher()
        state.announce = { announced.value.append($0) }
        state.receiveRequest = { request, _ in await receive(request) }
        state.subscribe()
        return state
    }

    static func testOutcome(_ report: AIRequestReport, id: String) -> AIRequestOutcome {
        AIRequestOutcome(
            id: id,
            title: "Trio test: 10 g carbs",
            source: "Trio test",
            shown: nil,
            report: report,
            askedOn: nil,
            approvedOn: nil,
            declinedOn: nil
        )
    }

    @Test(
        "A test request refused on arrival shows why in place of \"Sent\", and VoiceOver hears that instead"
    ) func refusedTestRequestShowsWhy() async {
        let outcomes = PassthroughSubject<AIRequestOutcome, Never>()
        let announced = TestBox<[String]>([])
        let box = TestBox<AIAssistantsConfig.StateModel?>(nil)
        let state = makeTestingState(outcomes: outcomes, announced: announced) { request in
            // Trio refuses it while taking it in, before the send returns.
            outcomes.send(Self.testOutcome(.failed(reason: "Over your max IOB", carbsLogged: false), id: request.id))
            _ = await eventuallyTrue { box.value?.testResult != nil }
        }
        box.value = state

        await state.sendTestRequest(.dryRun)

        #expect(state.testResult?.headline == "Not given")
        #expect(state.testResult?.detail == "Over your max IOB. Nothing was logged.")
        #expect(state.testCount == 1)
        #expect(announced.value == ["Not given. Over your max IOB. Nothing was logged."])
    }

    @Test(
        "A test request's final result shows in place of \"Sent\" when it comes back, and VoiceOver hears both"
    ) func testRequestResultReplacesSent() async throws {
        let outcomes = PassthroughSubject<AIRequestOutcome, Never>()
        let announced = TestBox<[String]>([])
        let sentIDs = TestBox<[String]>([])
        let state = makeTestingState(outcomes: outcomes, announced: announced) { sentIDs.value.append($0.id) }

        await state.sendTestRequest(.dryRun)
        #expect(state.testResult == nil)
        #expect(announced.value == ["Sent. Check your watch."])

        let id = try #require(sentIDs.value.first)
        let shown = AIRequestShown(carbs: "10.00", fat: "0.00", protein: "0.00", units: "0.50")
        outcomes.send(Self.testOutcome(.dryRun(shown: shown), id: id))
        #expect(await eventuallyTrue { state.testResult != nil })
        #expect(state.testResult?.headline == "Test: would give 0.50\u{00A0}U")
        #expect(state.testResult?.detail == "Nothing was logged or given.")
        #expect(announced.value == [
            "Sent. Check your watch.",
            "Test: would give 0.50\u{00A0}U. Nothing was logged or given."
        ])
    }

    @Test(
        "Only the latest test request's result shows: another request's, or an older test's, is ignored"
    ) func onlyTheLatestTestRequestsResultShows() async throws {
        let outcomes = PassthroughSubject<AIRequestOutcome, Never>()
        let announced = TestBox<[String]>([])
        let sentIDs = TestBox<[String]>([])
        let state = makeTestingState(outcomes: outcomes, announced: announced) { sentIDs.value.append($0.id) }

        await state.sendTestRequest(.dryRun)
        await state.sendTestRequest(.real)
        let older = try #require(sentIDs.value.first)
        let latest = try #require(sentIDs.value.last)

        outcomes.send(Self.testOutcome(.replaced, id: older))
        outcomes.send(Self.testOutcome(.expired, id: "an-assistants-request"))
        outcomes.send(Self.testOutcome(.declined(on: .watch), id: latest))
        #expect(await eventuallyTrue { state.testResult != nil })
        #expect(state.testResult?.headline == "Declined")
        #expect(announced.value == ["Sent. Check your watch.", "Sent. Check your watch.", "Declined. Nothing was logged."])

        // The next test request starts again from "Sent".
        await state.sendTestRequest(.dryRun)
        #expect(state.testResult == nil)
        #expect(announced.value.last == "Sent. Check your watch.")
    }

    @Test("Without the request runtime no result is listened for") func testResultNeedsTheRuntime() async {
        let state = makeState()
        state.requestOutcomes = nil
        state.subscribe()
        state.receiveRequest = { _, _ in }
        await state.sendTestRequest(.dryRun)
        #expect(state.testResult == nil)
    }

    // MARK: - Approving from the notification

    @Test("Choosing to approve from the notification asks first and changes nothing") func oneGestureNeedsConfirmation() {
        let state = makeState()
        #expect(state.preferences.approvalStyle == .twoStep)
        state.requestApprovalStyle(.oneGesture)
        #expect(state.isConfirmingOneGesture)
        #expect(state.preferences.approvalStyle == .twoStep)
        state.confirmOneGesture()
        #expect(!state.isConfirmingOneGesture)
        #expect(state.preferences.approvalStyle == .oneGesture)
    }

    @Test("Canceling the question leaves Review on watch first") func cancellingOneGestureKeepsTwoSteps() {
        let state = makeState()
        state.requestApprovalStyle(.oneGesture)
        state.cancelOneGesture()
        #expect(!state.isConfirmingOneGesture)
        #expect(state.preferences.approvalStyle == .twoStep)
        // A confirmation with nothing asked changes nothing either.
        state.confirmOneGesture()
        #expect(state.preferences.approvalStyle == .twoStep)
    }

    @Test("Going back to Review on watch first needs no question") func twoStepAppliesAtOnce() {
        let state = makeState()
        state.preferences.approvalStyle = .oneGesture
        state.requestApprovalStyle(.twoStep)
        #expect(!state.isConfirmingOneGesture)
        #expect(state.preferences.approvalStyle == .twoStep)
    }

    @Test("Choosing the style already on asks nothing") func choosingTheCurrentStyleAsksNothing() {
        let state = makeState()
        state.preferences.approvalStyle = .oneGesture
        state.requestApprovalStyle(.oneGesture)
        #expect(!state.isConfirmingOneGesture)
        #expect(state.preferences.approvalStyle == .oneGesture)
        state.requestApprovalStyle(.twoStep)
        state.requestApprovalStyle(.twoStep)
        #expect(!state.isConfirmingOneGesture)
    }
}
