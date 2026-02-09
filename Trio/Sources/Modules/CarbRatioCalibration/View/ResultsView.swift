import SwiftUI

extension CarbRatioCalibration {
    struct ResultsView: View {
        @Bindable var state: StateModel

        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    // Header with result
                    resultHeader

                    // Glucose chart
                    if let testState = state.testState {
                        glucoseChart(testState: testState)
                    }

                    // Test summary
                    testSummary

                    // Recommendation
                    if let result = state.testState?.resultInterpretation {
                        recommendationSection(result: result)
                    }

                    Spacer()

                    // Action buttons
                    actionButtons
                }
            }
        }

        @ViewBuilder private var resultHeader: some View {
            VStack(spacing: 8) {
                resultIcon

                Text("Test Complete")
                    .font(.title2)
                    .fontWeight(.semibold)

                if let result = state.testState?.resultInterpretation {
                    Text(result.displayName)
                        .font(.headline)
                        .foregroundColor(resultColor(for: result))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top)
        }

        @ViewBuilder private var resultIcon: some View {
            let result = state.testState?.resultInterpretation

            ZStack {
                Circle()
                    .fill(resultColor(for: result).opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: resultIconName(for: result))
                    .font(.system(size: 40))
                    .foregroundColor(resultColor(for: result))
            }
        }

        @ViewBuilder private func glucoseChart(testState: CalibrationTestState) -> some View {
            VStack(spacing: 8) {
                Text("Glucose During Test")
                    .font(.headline)

                // Simple representation without actual chart data
                // In production, this would use the glucoseReadings array
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Start")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(state.formatGlucose(testState.startingGlucose)) \(state.unitsLabel)")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }

                        Spacer()

                        Image(systemName: deltaArrowIcon)
                            .font(.title)
                            .foregroundColor(resultColor(for: testState.resultInterpretation))

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("End")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(
                                "\(state.formatGlucose(testState.endingGlucose ?? testState.startingGlucose)) \(state.unitsLabel)"
                            )
                            .font(.title3)
                            .fontWeight(.semibold)
                        }
                    }

                    // Delta display
                    let delta = (testState.endingGlucose ?? testState.startingGlucose) - testState.startingGlucose
                    let deltaSign = delta >= 0 ? "+" : ""

                    Text("Change: \(deltaSign)\(state.formatGlucose(abs(delta))) \(state.unitsLabel)")
                        .font(.subheadline)
                        .foregroundColor(resultColor(for: testState.resultInterpretation))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(resultColor(for: testState.resultInterpretation).opacity(0.1))
                        .cornerRadius(8)

                    // Target range indicator
                    Text("Target range: ±\(state.formatGlucose(20)) \(state.unitsLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }

        @ViewBuilder private var testSummary: some View {
            VStack(spacing: 12) {
                Text("Test Summary")
                    .font(.headline)

                if let testState = state.testState {
                    VStack(spacing: 8) {
                        summaryRow(
                            label: "Tablets",
                            value: "\(testState.tabletCount) \(GlucoseTabletBrand.from(testState.tabletBrand).displayName)"
                        )
                        summaryRow(label: "Carbs", value: "\(testState.totalCarbs.formatted())g")
                        summaryRow(
                            label: "Bolus",
                            value: "\(testState.bolusAmount.formatted(.number.precision(.fractionLength(2))))U"
                        )
                        summaryRow(
                            label: "Carb Ratio Used",
                            value: "\(testState.carbRatioAtTestTime.formatted(.number.precision(.fractionLength(1)))) g/U"
                        )
                    }
                    .padding()
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(8)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }

        @ViewBuilder private func recommendationSection(result: CalibrationResult) -> some View {
            VStack(spacing: 12) {
                Text("Recommendation")
                    .font(.headline)

                Text(result.explanation)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if let suggestedRatio = state.testState?.suggestedNewRatio {
                    VStack(spacing: 8) {
                        HStack {
                            VStack {
                                Text("Current")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(
                                    "\(state.testState?.carbRatioAtTestTime.formatted(.number.precision(.fractionLength(1))) ?? "--") g/U"
                                )
                                .font(.title3)
                            }

                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)

                            VStack {
                                Text("Suggested")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(suggestedRatio.formatted(.number.precision(.fractionLength(1)))) g/U")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding()
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }

        @ViewBuilder private var actionButtons: some View {
            VStack(spacing: 12) {
                if state.testState?.suggestedNewRatio != nil {
                    Button {
                        state.showRatioUpdateOptions = true
                    } label: {
                        Text("Apply Suggested Ratio")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .confirmationDialog(
                        "Apply Ratio Change",
                        isPresented: $state.showRatioUpdateOptions,
                        titleVisibility: .visible
                    ) {
                        Button("Current time slot only") {
                            Task {
                                await state.applySuggestedRatio(option: .currentSlotOnly(timeRange: ""))
                                state.hideModal()
                            }
                        }
                        Button("All time slots") {
                            Task {
                                await state.applySuggestedRatio(option: .allSlots)
                                state.hideModal()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("How would you like to apply the new ratio?")
                    }
                }

                Button {
                    state.dismissResults()
                    state.hideModal()
                } label: {
                    Text(state.testState?.suggestedNewRatio != nil ? "Keep Current Ratio" : "Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }

        // MARK: - Helpers

        @ViewBuilder private func summaryRow(label: String, value: String) -> some View {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }

        private func resultColor(for result: CalibrationResult?) -> Color {
            switch result {
            case .ratioCorrect:
                return .green
            case .ratioTooWeak:
                return .orange
            case .ratioTooStrong:
                return .red
            case nil:
                return .secondary
            }
        }

        private func resultIconName(for result: CalibrationResult?) -> String {
            switch result {
            case .ratioCorrect:
                return "checkmark.circle.fill"
            case .ratioTooWeak:
                return "arrow.up.circle.fill"
            case .ratioTooStrong:
                return "arrow.down.circle.fill"
            case nil:
                return "questionmark.circle.fill"
            }
        }

        private var deltaArrowIcon: String {
            guard let testState = state.testState,
                  let endingGlucose = testState.endingGlucose
            else {
                return "arrow.right"
            }

            let delta = endingGlucose - testState.startingGlucose
            if delta > 10 {
                return "arrow.up.right"
            } else if delta < -10 {
                return "arrow.down.right"
            } else {
                return "arrow.right"
            }
        }
    }
}

#Preview {
    CarbRatioCalibration.ResultsView(state: CarbRatioCalibration.StateModel())
}
