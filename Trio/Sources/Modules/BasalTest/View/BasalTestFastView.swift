import SwiftUI

extension BasalTest {
    struct FastView: View {
        @Bindable var state: StateModel

        var body: some View {
            // Minutes are all a fast of hours needs, so the countdown ticks once a minute.
            TimelineView(.everyMinute) { context in
                SettingsTestScreen(paintsBackground: false) {
                    countdown(now: context.date)
                    // What to do about a low comes before the chart, so it is on screen without scrolling.
                    rulesCard
                    glucoseCard
                } footer: {
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

        /// How long until the user can eat, and when that is.
        private func countdown(now: Date) -> some View {
            let end = state.test?.plannedEnd ?? now
            let total = state.test?.plannedDuration ?? 1
            let remaining = max(0, end.timeIntervalSince(now))
            // Rounded up, so the last minute reads "1 m left" and not "0 m".
            let minutesLeft = (remaining / 60).rounded(.up)
            return SettingsTestCard {
                VStack(spacing: 10) {
                    Text("\(SettingsTestFormat.duration(minutesLeft * 60)) left")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    SettingsTestProgressBar(progress: 1 - remaining / max(1, total))
                    Text("Ends at \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                        band: state.steadyBand
                    )

                    // Only with an ISF and a basal to work the band out from.
                    if state.steadyBand != nil {
                        Text(
                            "Inside the green band, the change is smaller than the docs' smallest basal change (\(state.stepPercent)%)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

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

        /// The low comes first: it is the one thing to act on during a fast. Red is kept for it, and the rules use
        /// neutral glyphs, so none of them looks like a failed check.
        private var rulesCard: some View {
            SettingsTestCard(title: String(localized: "During the fast")) {
                rule(
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red),
                    "Feeling low? Treat it as usual and log the carbs. That stops the test.",
                    emphasized: true
                )
                rule(nosign, "Don't eat. Anything you log stops the test.")
                rule(nosign, "Don't give a bolus.")
                rule(dot, "Quiet activity only; skip hard exercise.")
                rule(dot, "You can leave this screen. Trio still ends the test for a low or for carbs you log.")
            }
        }

        private var nosign: some View {
            Image(systemName: "nosign").foregroundStyle(.secondary)
        }

        private var dot: some View {
            Text(verbatim: "•").foregroundStyle(.secondary)
        }

        private func rule(_ icon: some View, _ text: LocalizedStringKey, emphasized: Bool = false) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
        }
    }
}
