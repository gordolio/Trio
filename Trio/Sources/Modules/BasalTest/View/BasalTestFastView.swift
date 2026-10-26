import SwiftUI

extension BasalTest {
    struct FastView: View {
        @Bindable var state: StateModel

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SettingsTestScreen {
                    countdown(now: context.date)
                    glucoseCard
                    rulesCard
                } footer: {
                    if state.isHigh {
                        Text("Glucose is already high, which tells you what you need to know. You can end the test now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("Stop Test") { state.showStopOptions = true }
                        .buttonStyle(.testSecondary)
                }
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await state.checkRunningTest() }
            }
            .confirmationDialog("Stop the test?", isPresented: $state.showStopOptions, titleVisibility: .visible) {
                Button("End Now and See Result") { Task { await state.endEarly() } }
                Button("Discard Test", role: .destructive) { state.discard() }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("Your usual dosing mode comes back either way.")
            }
        }

        // MARK: - Pieces

        private func countdown(now: Date) -> some View {
            let end = state.test?.plannedEnd ?? now
            let total = state.test?.plannedDuration ?? 1
            let remaining = max(0, end.timeIntervalSince(now))
            return SettingsTestCard {
                VStack(spacing: 10) {
                    Text("Time left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(SettingsTestFormat.clock(remaining))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    SettingsTestProgressBar(progress: 1 - remaining / max(1, total))
                    if let test = state.test {
                        Text("\(test.timeBlock) fast, started \(test.startedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }

        private var glucoseCard: some View {
            SettingsTestCard(title: String(localized: "Glucose")) {
                if let test = state.test {
                    let now = state.currentGlucose
                    SettingsTestMetricRow(metrics: [
                        SettingsTestMetric(title: String(localized: "Start"), value: state.format(test.startGlucose)),
                        SettingsTestMetric(title: String(localized: "Now"), value: now.map(state.format) ?? "--"),
                        SettingsTestMetric(
                            title: String(localized: "Change"),
                            value: now.map { state.formatChange($0 - test.startGlucose) } ?? "--"
                        )
                    ])

                    SettingsTestGlucoseChart(
                        points: state.runningReadings.map { SettingsTestGlucosePoint(date: $0.date, glucose: $0.glucose) },
                        units: state.glucoseUnits,
                        band: (test.startGlucose - Config.steadyTolerance) ... (test.startGlucose + Config.steadyTolerance)
                    )

                    Text(
                        "The green band is steady: within \(state.formatWithUnits(Config.steadyTolerance)) of where you started."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if state.readingIsStale {
                        Label(
                            "No recent glucose readings. Trio can't watch for lows without them.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }

        private var rulesCard: some View {
            SettingsTestCard(title: String(localized: "During the fast")) {
                rule("xmark.circle.fill", .red, "Don't eat or log carbs")
                rule("xmark.circle.fill", .red, "Don't give a bolus")
                rule("checkmark.circle.fill", .green, "You can close the app. Trio keeps watching")
                rule("checkmark.circle.fill", .green, "Go about quiet activity; skip hard exercise")
                Text("If you feel low, treat it. The test ends and your usual dosing returns.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        private func rule(_ icon: String, _ color: Color, _ text: LocalizedStringKey) -> some View {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                Text(text).font(.subheadline)
            }
        }
    }
}
