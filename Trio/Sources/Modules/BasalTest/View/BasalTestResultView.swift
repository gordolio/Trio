import SwiftUI

extension BasalTest {
    struct ResultView: View {
        @Bindable var state: StateModel

        var body: some View {
            if let test = state.test, let outcome = test.outcome {
                SettingsTestScreen {
                    header(for: outcome)

                    SettingsTestCard {
                        SettingsTestMetricRow(metrics: [
                            SettingsTestMetric(title: String(localized: "Start"), value: state.format(test.startGlucose)),
                            SettingsTestMetric(
                                title: String(localized: "End"),
                                value: state.format(test.endGlucose ?? test.startGlucose)
                            ),
                            SettingsTestMetric(
                                title: String(localized: "Change"),
                                value: state.formatChange((test.endGlucose ?? test.startGlucose) - test.startGlucose)
                            )
                        ])

                        SettingsTestGlucoseChart(
                            points: test.readings.map { SettingsTestGlucosePoint(date: $0.date, glucose: $0.glucose) },
                            units: state.glucoseUnits,
                            band: (test.startGlucose - Config.steadyTolerance) ... (test.startGlucose + Config.steadyTolerance)
                        )

                        Text(window(for: test))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsTestCard(title: String(localized: "What this means")) {
                        Text(meaning(for: outcome, test: test))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if outcome.isConclusive {
                            Divider()
                            Text(
                                "Change basal by about 10–20% at a time, only for the hours this test covered, then wait several days before testing again."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } footer: {
                    if outcome == .rising || outcome == .falling {
                        Button("Open Basal Rates") { state.showModal(for: .basalProfileEditor) }
                            .buttonStyle(.testSecondary)
                    }
                    Button("Done") { state.acknowledgeResult() }
                        .buttonStyle(.testPrimary)
                }
            }
        }

        // MARK: - Pieces

        private func header(for outcome: BasalTestOutcome) -> some View {
            SettingsTestHeader(
                icon: icon(for: outcome),
                title: title(for: outcome),
                subtitle: String(localized: "\(state.test?.timeBlock ?? "") basal test"),
                tint: tint(for: outcome)
            )
        }

        private func window(for test: BasalTestState) -> String {
            let start = test.startedAt.formatted(date: .omitted, time: .shortened)
            let end = (test.endedAt ?? test.plannedEnd).formatted(date: .omitted, time: .shortened)
            let reason: String
            switch test.endReason {
            case .low: reason = String(localized: ". Ended early: glucose went low.")
            case .endedEarly: reason = String(localized: ". You ended it early.")
            case .interrupted: reason = String(localized: ". Ended early: it was interrupted.")
            case .completed,
                 nil: reason = ""
            }
            return "\(start) – \(end)\(reason)"
        }

        private func title(for outcome: BasalTestOutcome) -> String {
            switch outcome {
            case .steady: return String(localized: "Basal looks right")
            case .rising: return String(localized: "Glucose rose")
            case .falling: return String(localized: "Glucose fell")
            case .inconclusive: return String(localized: "Too soon to tell")
            case .invalid: return String(localized: "Test interrupted")
            }
        }

        private func icon(for outcome: BasalTestOutcome) -> String {
            switch outcome {
            case .steady: return "checkmark.circle.fill"
            case .rising: return "arrow.up.right.circle.fill"
            case .falling: return "arrow.down.right.circle.fill"
            case .inconclusive: return "questionmark.circle.fill"
            case .invalid: return "exclamationmark.triangle.fill"
            }
        }

        private func tint(for outcome: BasalTestOutcome) -> Color {
            switch outcome {
            case .steady: return .green
            case .falling,
                 .rising: return .orange
            case .inconclusive: return .secondary
            case .invalid: return .red
            }
        }

        private func meaning(for outcome: BasalTestOutcome, test: BasalTestState) -> String {
            switch outcome {
            case .steady:
                return String(
                    localized: "Glucose stayed within \(state.formatWithUnits(Config.steadyTolerance)) of where it started. Your basal rates for this part of the day look right."
                )
            case .rising:
                return String(
                    localized: "Glucose climbed with no food and no extra insulin. That suggests basal for these hours is too low. A higher basal number would give more insulin."
                )
            case .falling:
                return String(
                    localized: "Glucose fell with no food and no extra insulin. That suggests basal for these hours is too high. A lower basal number would give less insulin."
                )
            case .inconclusive:
                return String(
                    localized: "The test ended before there was enough time to trust the result, and glucose hadn't moved far. Try again and let it run longer."
                )
            case .invalid:
                return test.interference
                    ?? String(localized: "Something changed during the fast, so the result can't be trusted. Try again.")
            }
        }
    }
}
