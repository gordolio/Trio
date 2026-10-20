import SwiftUI

extension AIAssistantsConfig {
    /// How the watch's answers and the wake-up push travel, and a request to try them with.
    struct TestingSection: View {
        @ObservedObject var state: StateModel

        var body: some View {
            Section(
                header: Text("Testing"),
                footer: Text("Approving it logs 10 g of carbs and gives Trio's dose.")
            ) {
                Picker("Send watch answers by", selection: $state.preferences.answerRoute) {
                    ForEach(AIRequestAnswerRoute.allCases, id: \.self) { route in
                        Text(route.title).tag(route)
                    }
                }
                Picker("Wake-up push", selection: $state.preferences.wakePushType) {
                    ForEach(AIWakePushType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                Button("Send a test request (10 g)") {
                    Task { await state.sendTestRequest() }
                }
                .disabled(!state.canSendTestRequest)
            }
            .listRowBackground(Color.chart)
        }
    }
}

private extension AIRequestAnswerRoute {
    var title: LocalizedStringKey {
        switch self {
        case .both:
            return "Both"
        case .watchOnly:
            return "Watch → iPhone only"
        case .serviceOnly:
            return "trio-rc only"
        }
    }
}

private extension AIWakePushType {
    var title: LocalizedStringKey {
        switch self {
        case .passive:
            return "Quiet alert"
        case .timeSensitive:
            return "Time-sensitive alert"
        case .background:
            return "Silent"
        }
    }
}
