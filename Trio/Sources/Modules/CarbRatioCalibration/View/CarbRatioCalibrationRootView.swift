import SwiftUI
import Swinject

extension CarbRatioCalibration {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()
        var body: some View {
            VStack(spacing: 0) {
                // Progress bar
                CalibrationProgressBar(currentStep: state.currentStep)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Content based on current step
                stepContent
                    .padding()
            }
            .navigationTitle("Carb Ratio Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Error", isPresented: .constant(state.errorMessage != nil)) {
                Button("OK") {
                    state.errorMessage = nil
                }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .confirmationDialog(
                "Deliver Bolus",
                isPresented: $state.showStartTestConfirmation,
                titleVisibility: .visible
            ) {
                Button("Deliver \(state.calculatedBolus.formatted(.number.precision(.fractionLength(2))))U Bolus") {
                    Task {
                        await state.executeTestBolus()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This will log \(state.totalCarbs.formatted())g carbs and deliver a \(state.calculatedBolus.formatted(.number.precision(.fractionLength(2))))U bolus. The 90-minute observation will begin immediately."
                )
            }
            .onAppear {
                configureView()
            }
        }

        @ViewBuilder private var stepContent: some View {
            switch state.currentStep {
            case .preflight:
                PreflightCheckView(state: state)
            case .prep:
                PrepPhaseView(state: state)
            case .test:
                TestPhaseView(state: state)
            case .observation:
                ObservationPhaseView(state: state)
            case .results:
                ResultsView(state: state)
            }
        }

        func configureView() {
            state.resolver = resolver
        }
    }
}

// MARK: - Preview

#Preview {
    Text("Carb Ratio Calibration")
}
