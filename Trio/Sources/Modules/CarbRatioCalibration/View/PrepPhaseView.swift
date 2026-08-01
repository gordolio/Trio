import SwiftUI

extension CarbRatioCalibration {
    struct PrepPhaseView: View {
        @Bindable var state: StateModel

        /// Timer to update the elapsed/remaining display every second
        @State private var now = Date()
        @State private var showCancelConfirmation = false
        private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        Text("Waiting for Conditions")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(
                            "A calibration override is active. We're monitoring until conditions are stable enough to begin the test."
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    .padding(.top)

                    // Timeout progress
                    VStack(spacing: 8) {
                        HStack {
                            Label(
                                formatTimeRemaining(state.prepTimeRemaining),
                                systemImage: "timer"
                            )
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(state.prepTimeRemaining < 600 ? .orange : .secondary)

                            Spacer()

                            Text("\(state.conditionsPassingCount)/\(state.conditionsTotalCount) conditions met")
                                .font(.subheadline)
                                .foregroundColor(
                                    state.conditionsPassingCount == state
                                        .conditionsTotalCount ? .green : .secondary
                                )
                        }

                        ProgressView(
                            value: min(1.0, state.prepElapsedTime / state.prepTimeoutDuration)
                        )
                        .tint(state.prepTimeRemaining < 600 ? .orange : .accentColor)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Conditions checklist
                    VStack(spacing: 16) {
                        Text("Conditions Required")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        conditionCheckRow(
                            title: "BG in Range",
                            subtitle: state.currentGlucose
                                .map {
                                    "\(state.formatGlucose($0)) \(state.unitsLabel) (need \(state.targetRangeDescription))"
                                } ??
                                "No data yet",
                            isPassing: state.isGlucoseInRange
                        )

                        conditionCheckRow(
                            title: "Stable Trend",
                            subtitle: state.glucoseFlatSubtitle,
                            isPassing: state.isGlucoseFlat
                        )

                        conditionCheckRow(
                            title: "IOB Near Zero",
                            subtitle: "\(state.currentIOB.formatted(.number.precision(.fractionLength(1)))) U (need \u{2264} 0.1 U)",
                            isPassing: state.isIOBNearZero
                        )

                        conditionCheckRow(
                            title: "COB Near Zero",
                            subtitle: "\(state.currentCOB.formatted(.number.precision(.fractionLength(0)))) g (need \u{2264} 5 g)",
                            isPassing: state.isCOBNearZero
                        )
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Status indicators
                    VStack(spacing: 16) {
                        statusRow(
                            icon: "bolt.slash.fill",
                            title: "Override Active",
                            subtitle: "SMBs disabled via calibration override",
                            color: .orange
                        )

                        statusRow(
                            icon: "waveform.path.ecg",
                            title: "Basal Active",
                            subtitle: "Basal insulin and temp basals continue normally",
                            color: .green
                        )

                        statusRow(
                            icon: "clock.fill",
                            title: "Auto-checking",
                            subtitle: "Conditions checked on open and every 5 minutes",
                            color: .blue
                        )
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Instructions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("While you wait:")
                            .font(.headline)

                        instructionRow(number: 1, text: "You can close this app")
                        instructionRow(number: 2, text: "Avoid eating or bolusing")
                        instructionRow(number: 3, text: "You'll be notified when ready")
                        instructionRow(number: 4, text: "Have your glucose tablets ready")
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    Spacer()

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
            .onReceive(timer) { self.now = $0 }
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
        }

        // MARK: - Subviews

        @ViewBuilder private func conditionCheckRow(title: String, subtitle: String, isPassing: Bool) -> some View {
            HStack(spacing: 12) {
                Image(systemName: isPassing ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isPassing ? .green : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }

        @ViewBuilder private func statusRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }

        @ViewBuilder private func instructionRow(number: Int, text: String) -> some View {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor)
                    .clipShape(Circle())

                Text(text)
                    .font(.subheadline)
            }
        }

        // MARK: - Helpers

        private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            if mins > 0 {
                return "\(mins)m \(secs)s remaining"
            }
            return "\(secs)s remaining"
        }
    }
}

#Preview {
    CarbRatioCalibration.PrepPhaseView(state: CarbRatioCalibration.StateModel())
}
