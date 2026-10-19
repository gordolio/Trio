import AuthenticationServices
import SwiftUI
import Swinject

extension AIAssistantsConfig {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @State private var showingUnlinkConfirmation = false

        var body: some View {
            Form {
                switch state.linkState {
                case .notLinked:
                    signInSection(header: nil)
                case let .linked(host, lastUpload, lastError):
                    linkedSection(host: host, lastUpload: lastUpload, lastError: lastError)
                case let .signedOut(host):
                    signInSection(header: Text("Signed out of \(host). Sign in again to resume updates."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("AI Assistants")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
        }

        private var footer: some View {
            Text(
                "Lets assistants like ChatGPT and Grok read your glucose and loop status. Nothing here can change your treatments."
            )
        }

        private func signInSection(header: Text?) -> some View {
            Section(header: header, footer: footer) {
                if state.serviceURL == nil {
                    Text("This build isn't set up for AI Assistants.")
                    Text(
                        "To turn it on, set AI_ASSISTANTS_SERVICE_HOST (a GitHub secret, or ConfigOverride.xcconfig) and build Trio again."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    SignInWithAppleButton(.signIn, onRequest: state.prepare) { result in
                        Task { await state.complete(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .disabled(state.isSigningIn)
                    .opacity(state.isSigningIn ? 0.5 : 1)
                }

                if state.isSigningIn {
                    ProgressView("Signing in…")
                }
                if let errorMessage = state.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .listRowBackground(Color.chart)
        }

        private func linkedSection(host: String, lastUpload: Date?, lastError: String?) -> some View {
            Section(footer: footer) {
                LabeledContent("Linked to", value: host)
                if let lastUpload {
                    LabeledContent("Last update") {
                        Text(lastUpload, style: .relative)
                    }
                } else {
                    Text("Waiting for first update").foregroundStyle(.secondary)
                }
                if let lastError {
                    Text(lastError).foregroundStyle(.red)
                }
                Button("Unlink", role: .destructive) {
                    showingUnlinkConfirmation = true
                }
                .confirmationDialog(
                    "Unlink from \(host)?",
                    isPresented: $showingUnlinkConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Unlink", role: .destructive) {
                        Task { await state.unlink() }
                    }
                } message: {
                    Text("Assistants will stop getting updates from Trio.")
                }
            }
            .listRowBackground(Color.chart)
        }
    }
}
