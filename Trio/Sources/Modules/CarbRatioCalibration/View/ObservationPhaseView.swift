import SwiftUI

extension CarbRatioCalibration {
    struct ObservationPhaseView: View {
        @Bindable var state: StateModel

        @State private var currentTime = Date()
        @State private var isCompletingObservation = false
        @State private var showCancelConfirmation = false
        let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "timer")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)

                        Text("Test in Progress")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Monitoring your glucose response. You'll be notified when results are ready.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)

                    // Countdown timer
                    VStack(spacing: 12) {
                        Text("Time Remaining")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(formatTimeRemaining(now: currentTime))
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentColor)

                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor)
                                    .frame(width: geometry.size.width * progressValue, height: 8)
                                    .animation(.linear(duration: 1.0), value: progressValue)
                            }
                        }
                        .frame(height: 8)
                        .padding(.horizontal, 40)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Test details
                    VStack(spacing: 16) {
                        Text("Test Details")
                            .font(.headline)

                        HStack(spacing: 24) {
                            testDetailItem(
                                title: "Carbs",
                                value: "\(state.testState?.totalCarbs.formatted() ?? "--")g"
                            )

                            Divider()
                                .frame(height: 40)

                            testDetailItem(
                                title: "Bolus",
                                value: "\(state.testState?.bolusAmount.formatted(.number.precision(.fractionLength(2))) ?? "--")U"
                            )

                            Divider()
                                .frame(height: 40)

                            testDetailItem(
                                title: "Starting BG",
                                value: "\(state.testState?.startingGlucose ?? 0)"
                            )
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Instructions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("During the Test")
                            .font(.headline)

                        instructionRow(icon: "xmark.circle", text: "Do not eat anything", color: .red)
                        instructionRow(icon: "xmark.circle", text: "Do not take additional insulin", color: .red)
                        instructionRow(icon: "checkmark.circle", text: "You can close this app", color: .green)
                        instructionRow(icon: "checkmark.circle", text: "Normal activity is fine", color: .green)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    Spacer()

                    // Early completion button (for testing/demo)
                    if state.observationProgress >= 1.0 || state.testState?.observationEndDate ?? Date.distantFuture <= Date() {
                        Button {
                            Task {
                                await state.completeObservation()
                            }
                        } label: {
                            Text("View Results")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // Cancel button
                    Button(role: .destructive) {
                        showCancelConfirmation = true
                    } label: {
                        Text("Cancel Test")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .confirmationDialog(
                "Cancel Calibration Test?",
                isPresented: $showCancelConfirmation,
                titleVisibility: .visible
            ) {
                Button("Cancel Test", role: .destructive) {
                    Task { await state.cancelTest() }
                }
                Button("Continue", role: .cancel) {}
            } message: {
                Text(
                    "This will cancel the calibration test, deactivate the calibration override, and restore your previous settings. Any progress will be lost."
                )
            }
            .onReceive(timer) { _ in
                currentTime = Date()

                // Check if observation is complete (guard against duplicate calls)
                if let endDate = state.testState?.observationEndDate,
                   endDate <= Date(),
                   !isCompletingObservation
                {
                    isCompletingObservation = true
                    Task {
                        await state.completeObservation()
                    }
                }
            }
        }

        private var progressValue: Double {
            observationProgress(now: currentTime)
        }

        private func formatTimeRemaining(now: Date) -> String {
            guard let endDate = state.testState?.observationEndDate else { return "00:00" }
            let total = max(0, Int(endDate.timeIntervalSince(now)))
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            }
            return String(format: "%02d:%02d", minutes, seconds)
        }

        private func observationProgress(now: Date) -> Double {
            guard let endDate = state.testState?.observationEndDate else { return 0 }
            let totalDuration: TimeInterval = 90 * 60
            let remaining = max(0, endDate.timeIntervalSince(now))
            return min(1.0, max(0, 1.0 - remaining / totalDuration))
        }

        @ViewBuilder private func testDetailItem(title: String, value: String) -> some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }

        @ViewBuilder private func instructionRow(icon: String, text: String, color: Color) -> some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(color)

                Text(text)
                    .font(.subheadline)
            }
        }
    }
}

#Preview {
    CarbRatioCalibration.ObservationPhaseView(state: CarbRatioCalibration.StateModel())
}
