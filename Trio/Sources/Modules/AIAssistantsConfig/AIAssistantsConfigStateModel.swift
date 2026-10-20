import AuthenticationServices
import Combine
import SwiftUI

extension AIAssistantsConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var service: AIAssistantsService!

        /// The service this build signs in to; `nil` if the build doesn't name one.
        var serviceURL = StateModel.serviceURL(
            fromBuildSetting: Bundle.main.object(forInfoDictionaryKey: "AIAssistantsServiceHost") as? String
        )
        @Published var linkState: AIAssistantsLinkState = .notLinked
        @Published var account: AIAssistantsAccount?
        @Published var errorMessage: String?
        @Published var isSigningIn = false
        @Published private(set) var isSigningOut = false
        /// Goes up by one for each copy, to show the "Copied" confirmation again.
        @Published private(set) var copyCount = 0
        @Published private(set) var copiedMessage = ""

        /// What the request settings on the screen show. Kept in sync with `preferencesStore` once `subscribe()` ran.
        @Published var preferences = AIAssistantsPreferences()
        /// Where the request preferences are kept: the request runtime's store, unless a test sets another.
        var preferencesStore: AIAssistantsPreferencesStore? = AIRequestsRuntime.shared?.preferences
        /// Hands a request to Trio, as the coordinator receives it. `nil` while the request runtime isn't running.
        var receiveRequest: ((AIMealRequest, AIRequestChannel) async -> Void)? = AIRequestsRuntime.shared
            .map { runtime in { request, channel in await runtime.coordinator.receive(request, via: channel) } }

        var pasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }
        /// Tells VoiceOver what was copied; the confirmation on screen is hidden from it.
        var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

        var authClient = AIAssistantsAuthClient()
        /// Generated for each Apple request; Apple gets its hash, the service gets the raw value.
        private var nonce: AppleNonce?

        override func subscribe() {
            service.state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.linkState = $0 }
                .store(in: &lifetime)
            service.account
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.account = $0 }
                .store(in: &lifetime)
            subscribeToPreferences()
        }

        /// Both ways, and neither echoes: each side writes only a value that differs from what it has. A change
        /// in the store reaches the screen on the main queue as the store's value of that moment, not the value
        /// that was sent. With the sent values, two changes made before the first one arrives would overwrite
        /// each other back and forth without end.
        private func subscribeToPreferences() {
            guard let store = preferencesStore else { return }
            preferences = store.value
            store.changes
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    let latest = store.value
                    guard let self, self.preferences != latest else { return }
                    self.preferences = latest
                }
                .store(in: &lifetime)
            $preferences
                .dropFirst()
                .removeDuplicates()
                .sink { preferences in
                    guard store.value != preferences else { return }
                    store.value = preferences
                }
                .store(in: &lifetime)
        }

        // MARK: - Sign in with Apple

        func prepare(_ request: ASAuthorizationAppleIDRequest) {
            let nonce = AppleNonce.generate()
            self.nonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce.hashed
        }

        @MainActor func complete(_ result: Result<ASAuthorization, Error>) async {
            switch result {
            case let .failure(error):
                fail(with: error)
            case let .success(authorization):
                let appleID = authorization.credential as? ASAuthorizationAppleIDCredential
                guard let appleID,
                      let credential = appleCredential(
                          identityToken: appleID.identityToken,
                          givenName: appleID.fullName?.givenName,
                          familyName: appleID.fullName?.familyName
                      )
                else {
                    fail(with: ASAuthorizationError(.failed))
                    return
                }
                await signIn(credential: credential)
            }
        }

        /// Pairs Apple's identity token with the raw nonce from `prepare`.
        func appleCredential(identityToken: Data?, givenName: String?, familyName: String?) -> AppleCredential? {
            guard let identityToken, let token = String(data: identityToken, encoding: .utf8), let nonce else {
                return nil
            }
            return AppleCredential(identityToken: token, rawNonce: nonce.raw, givenName: givenName, familyName: familyName)
        }

        @MainActor func signIn(credential: AppleCredential) async {
            guard let baseURL = serviceURL else {
                errorMessage = String(localized: "This build isn't set up for AI Assistants.")
                return
            }
            errorMessage = nil
            isSigningIn = true
            defer { isSigningIn = false }
            do {
                let signIn = try await authClient.signIn(with: credential, baseURL: baseURL)
                await service.completeLink(baseURL: baseURL, tokens: signIn.tokens, account: signIn.account)
            } catch AIAssistantsAuthError.notInvited {
                errorMessage = String(localized: "This Apple ID isn't on the invite list.")
            } catch AIAssistantsAuthError.unreachable {
                let host = baseURL.host ?? baseURL.absoluteString
                errorMessage = String(localized: "Couldn't reach \(host). Try again.")
            } catch {
                debug(.service, "AI Assistants: sign-in failed: \(error)")
                let reason = Self.shortReason(error)
                errorMessage = String(localized: "Couldn't sign in (\(reason)). Try again.")
            }
        }

        @MainActor func fail(with error: Error) {
            guard AIAssistantsAuthClient.mapAppleError(error) != .cancelled else { return }
            debug(.service, "AI Assistants: Sign in with Apple failed: \(error)")
            errorMessage = String(localized: "Sign in with Apple didn't finish. Try again.")
        }

        /// Sign out deletes the device on the service, the same as Unlink did. Offline, Trio still
        /// signs out, and says the service may keep the last status.
        @MainActor func signOut() async {
            errorMessage = nil
            isSigningOut = true
            defer { isSigningOut = false }
            if await !service.unlink() {
                errorMessage = String(
                    localized: "Signed out, but Trio couldn't reach the service, so assistants may still see your last status. Sign in and sign out again when you're online."
                )
            }
        }

        // MARK: - Test request

        var canSendTestRequest: Bool {
            receiveRequest != nil
        }

        /// Asks Trio for 10 g of carbs as if an assistant had sent it, to try the approval on the watch and
        /// the iPhone. It lasts five minutes, and Trio's dose for it is worked out as for any request.
        @MainActor func sendTestRequest() async {
            guard let receiveRequest else { return }
            let now = Date()
            let request = AIMealRequest(
                id: UUID().uuidString,
                source: "Test",
                description: "test request",
                carbs: 10,
                fat: 0,
                protein: 0,
                createdAt: now,
                expiresAt: now.addingTimeInterval(5 * 60)
            )
            await receiveRequest(request, .local)
        }

        // MARK: - Copying

        @MainActor func copyConnectorURL() {
            guard let connectorURL else { return }
            copy(connectorURL.absoluteString, confirmation: String(localized: "Connector URL copied"))
        }

        @MainActor func copyQuestion(_ question: String) {
            copy(question, confirmation: String(localized: "Question copied"))
        }

        @MainActor private func copy(_ text: String, confirmation: String) {
            pasteboard(text)
            copiedMessage = confirmation
            copyCount += 1
            announce(confirmation)
        }

        // MARK: - Helpers

        /// `https://` plus the `AI_ASSISTANTS_SERVICE_HOST` build setting, for example `trio-rc.gordol.io`.
        /// It's set in ConfigOverride.xcconfig, or from the GitHub secret of that name. The setting
        /// holds only the host because xcconfig reads `//` as the start of a comment.
        static func serviceURL(fromBuildSetting value: String?) -> URL? {
            var address = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !address.isEmpty, !address.hasPrefix("$(") else { return nil }
            if !address.contains("://") {
                address = "https://" + address
            }
            while address.hasSuffix("/"), !address.hasSuffix("://") {
                address.removeLast()
            }
            guard let url = URL(string: address), url.scheme == "https", url.host?.isEmpty == false else { return nil }
            return url
        }

        private static func shortReason(_ error: Error) -> String {
            switch error as? AIAssistantsAuthError {
            case .network:
                return String(localized: "offline")
            case let .http(status):
                return String(localized: "error \(status)")
            case let .missingCode(code):
                return code ?? String(localized: "no code")
            case .stateMismatch:
                return String(localized: "state mismatch")
            case .invalidGrant:
                return String(localized: "invalid grant")
            case .appleFailed,
                 .cancelled,
                 .none,
                 .notInvited,
                 .unreachable:
                return String(localized: "unexpected error")
            }
        }
    }
}
