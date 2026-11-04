import SwiftUI
import Swinject

extension ISFTest {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        var body: some View {
            WizardLayout(state: state)
                .navigationTitle("ISF Test")
                .navigationBarTitleDisplayMode(.inline)
                .alert("Something went wrong", isPresented: .constant(state.errorMessage != nil)) {
                    Button("OK") { state.errorMessage = nil }
                } message: {
                    Text(state.errorMessage ?? "")
                }
                .onAppear(perform: configureView)
        }
    }

    /// The step bar and the current step, on Trio's background.
    struct WizardLayout: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(AppState.self) private var appState

        let state: StateModel

        var body: some View {
            VStack(spacing: 0) {
                SettingsTestStepBar(current: state.step, skipped: state.skippedSteps)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                switch state.step {
                case .check: CheckView(state: state)
                case .settle: SettleView(state: state)
                case .raise: RaiseView(state: state)
                case .dose: DoseView(state: state)
                case .wait: WaitView(state: state)
                case .result: ResultView(state: state)
                }
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
        }
    }
}
