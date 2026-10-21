import SwiftUI

extension AIAssistantsConfig {
    /// Requests to try the approval with, and under "Delivery (advanced)" how the watch's answers and the wake-up
    /// push travel.
    struct TestingSection: View {
        @ObservedObject var state: StateModel
        @State private var isConfirmingRealTest = false

        var body: some View {
            Section {
                Button("Send a test request (10 g)") {
                    Task { await state.sendTestRequest(.dryRun) }
                }
                .disabled(!state.canSendTestRequest)
                .sensoryFeedback(.success, trigger: state.testCount)
            } header: {
                Text("Testing")
            } footer: {
                Text("Goes to your watch, then your iPhone, the way an assistant's would. Nothing is given.")
            }
            .listRowBackground(Color.chart)

            Section {
                Button("Send a real test request (10 g)") {
                    isConfirmingRealTest = true
                }
                .disabled(!state.canSendTestRequest)
                .confirmationDialog(
                    "Send a real test request?",
                    isPresented: $isConfirmingRealTest,
                    titleVisibility: .visible
                ) {
                    Button("Send") {
                        Task { await state.sendTestRequest(.real) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Approving it logs 10 g of carbs and gives Trio's real dose for them. Only approve if you're eating 10 g now."
                    )
                }
            } footer: {
                // It stays until the next send; a timer would only take it away while someone is reading. Once Trio says
                // how the latest test ended, that takes the place of "Sent". The state model tells VoiceOver either way.
                if let result = state.testResult {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.headline)
                            .fontWeight(.semibold)
                        Text(result.detail)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                } else if state.testCount > 0 {
                    Text(String(
                        localized: "Sent. Check your watch.",
                        comment: "VoiceOver, and the settings footer: a test request was sent to Trio"
                    ))
                        .font(.footnote)
                }
            }
            .listRowBackground(Color.chart)

            Section {
                DisclosureGroup("Delivery (advanced)") {
                    Picker("Send watch answers by", selection: $state.preferences.answerRoute) {
                        ForEach(AIRequestAnswerRoute.allCases, id: \.self) { route in
                            Text(route.title).tag(route)
                        }
                    }
                    Text(
                        "How the watch's answer gets back to Trio. Use Both, which is fastest and most reliable. The others test one path and can be slower."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Picker("Wake-up push", selection: $state.preferences.wakePushType) {
                        ForEach(AIWakePushType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    Text(
                        "How trio-rc wakes Trio for a new request. Quiet adds a silent \"Checking for requests\" notification that Trio removes. Time-sensitive shows it as a banner, even in a Focus. Silent shows nothing, but iOS may delay it."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.chart)
        }
    }
}

private extension AIRequestAnswerRoute {
    var title: LocalizedStringKey {
        switch self {
        case .both:
            return "Both (recommended)"
        case .watchOnly:
            return "iPhone only"
        case .serviceOnly:
            return "trio-rc only"
        }
    }
}

private extension AIWakePushType {
    var title: LocalizedStringKey {
        switch self {
        case .passive:
            return "Quiet alert (recommended)"
        case .timeSensitive:
            return "Time-sensitive alert"
        case .background:
            return "Silent"
        }
    }
}
