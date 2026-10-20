import AuthenticationServices
import SwiftUI
import Swinject

extension AIAssistantsConfig {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        var body: some View {
            ContentView(state: state)
                .onAppear(perform: configureView)
        }
    }

    /// The screen, apart from `RootView` so previews and tests can show it with a state model they
    /// seed themselves, without a resolver.
    struct ContentView: View {
        @ObservedObject var state: StateModel

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @State private var showingSignOutConfirmation = false

        var body: some View {
            Form {
                HeaderView()
                if state.serviceURL == nil {
                    unconfiguredSection
                } else {
                    if state.isLinked {
                        AccountSection(state: state)
                    } else {
                        signInSection
                    }
                    ConnectSection(state: state)
                }
                QuestionsSection(state: state)
                ApprovalSection(state: state)
                TestingSection(state: state)
                if state.isLinked {
                    signOutSection
                }
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("AI Assistants")
            .navigationBarTitleDisplayMode(.inline)
            .copiedToast(message: state.copiedMessage, trigger: state.copyCount)
        }

        private var unconfiguredSection: some View {
            Section {
                Text("This build isn't set up for AI Assistants.")
                Text(
                    "To turn it on, set AI_ASSISTANTS_SERVICE_HOST (a GitHub secret, or ConfigOverride.xcconfig) and build Trio again."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.chart)
        }

        private var signInSection: some View {
            Section(
                header: Text("Account"),
                footer: Text("Use the same Apple ID when an assistant asks you to sign in.")
            ) {
                if case .signedOut = state.linkState {
                    Text("You've been signed out. Sign in again to keep sharing.")
                }
                SignInWithAppleButton(.signIn, onRequest: state.prepare) { result in
                    Task { await state.complete(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .disabled(state.isSigningIn)
                .opacity(state.isSigningIn ? 0.5 : 1)

                if state.isSigningIn {
                    ProgressView("Signing in…")
                }
                if let errorMessage = state.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .listRowBackground(Color.chart)
        }

        private var signOutSection: some View {
            Section {
                if state.isSigningOut {
                    ProgressView("Signing out…")
                        .frame(maxWidth: .infinity)
                }
                Button("Sign Out", role: .destructive) {
                    showingSignOutConfirmation = true
                }
                .frame(maxWidth: .infinity)
                .disabled(state.isSigningOut)
                .confirmationDialog(
                    "Sign out of AI Assistants?",
                    isPresented: $showingSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task { await state.signOut() }
                    }
                } message: {
                    Text(
                        "Trio stops sharing, and the status your assistants can see is deleted. You can sign in again anytime."
                    )
                }
            }
            .listRowBackground(Color.chart)
        }
    }
}
