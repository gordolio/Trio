import SwiftUI

extension ISFTest {
    /// The docs' 4 hours after the bolus: the time left, what ends the test, and glucose since the bolus against the
    /// user's target.
    struct WaitView: View {
        @Bindable var state: StateModel

        var body: some View {
            // Minutes are all a wait of hours needs, so the countdown ticks once a minute.
            TimelineView(.everyMinute) { context in
                SettingsTestScreen(paintsBackground: false) {
                    countdown(now: context.date)
                    // What ends the test comes before the chart, so it is on screen without scrolling.
                    rulesCard
                    glucoseCard
                } footer: {
                    Button("End Test") { state.showStopOptions = true }
                        .buttonStyle(.testSecondary)
                        // On the button, so where the dialog shows as a popover it points at the button.
                        .confirmationDialog("End the test?", isPresented: $state.showStopOptions, titleVisibility: .visible) {
                            Button("End Test", role: .destructive) { Task { await state.endEarly() } }
                            Button("Keep Going", role: .cancel) {}
                        } message: {
                            // A low Trio suspended for before End Test was tapped still gives its result.
                            Text(
                                "There will be no result unless Trio suspended for a low during the test. Your usual dosing mode comes back."
                            )
                        }
                }
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await state.checkRunningTest() }
            }
        }

        // MARK: - Pieces

        /// How long until the 4 hours are up, and the bolus they run from.
        private func countdown(now: Date) -> some View {
            let end = state.test?.plannedEnd ?? now
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
                    SettingsTestProgressBar(progress: 1 - remaining / Config.docsWait)
                    if let bolusText {
                        Text(bolusText)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Ends at \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }

        /// "Bolus 2.24 U at 2:20 PM", or without the units when the pump recorded none, and, in a test that counts it,
        /// "· 0.30 U on board counted" once it has been read.
        private var bolusText: String? {
            guard let test = state.test, let bolusAt = test.bolusAt else { return nil }
            let time = bolusAt.formatted(date: .omitted, time: .shortened)
            let bolus = test.bolusUnits.map { String(localized: "Bolus \(state.formatUnits($0)) U at \(time)") }
                ?? String(localized: "Bolus at \(time)")
            guard test.iobHandling == .count, let iob = test.iobAtBolus else { return bolus }
            // The amount stays with its unit and "on board" stays together; the line can still break between the rest.
            let amount = SettingsTestFormat.keepTogether(state.formatSignedUnits(iob), unit: "U")
            let counted = String(localized: "\(amount) on board counted")
                .replacingOccurrences(of: "on board", with: "on\u{00A0}board")
            return bolus + " · " + counted
        }

        /// The low comes first: it is the one thing to act on during the wait. Red is kept for it, and the other rule
        /// uses a neutral glyph, so it doesn't look like a failed check.
        private var rulesCard: some View {
            SettingsTestCard(title: String(localized: "During the test")) {
                SettingsTestDocsQuote(text: Docs.waitFourHours)
                rule(
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red),
                    "If Trio suspends insulin for a low, the test ends: treat the low as usual.",
                    emphasized: true
                )
                // Logged, food or a treated low ends the test; unlogged, it would read as the ISF.
                rule(
                    Image(systemName: "nosign").foregroundStyle(.secondary),
                    "If you eat or treat a low, log it. The test then ends without a result, so it can't mislead you."
                )
                rule(
                    Image(systemName: "nosign").foregroundStyle(.secondary),
                    "Another bolus also ends the test without a result."
                )
            }
        }

        private var glucoseCard: some View {
            SettingsTestCard(title: String(localized: "Glucose since the bolus")) {
                if let test = state.test {
                    let now = state.currentGlucose
                    let start = test.startGlucose
                    SettingsTestMetricRow(metrics: [
                        SettingsTestMetric(title: String(localized: "Start"), value: start.map(state.format) ?? "--"),
                        SettingsTestMetric(title: String(localized: "Now"), value: now.map(state.format) ?? "--"),
                        SettingsTestMetric(
                            title: String(localized: "Change"),
                            value: start.flatMap { start in now.map { state.formatChange($0 - start) } } ?? "--"
                        )
                    ])

                    // With nothing to draw yet, a line says so instead of an empty chart.
                    if state.runningReadings.isEmpty {
                        Text("No readings since the bolus yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        SettingsTestGlucoseChart(
                            points: state.runningReadings.map { SettingsTestGlucosePoint(date: $0.date, glucose: $0.glucose) },
                            units: state.glucoseUnits,
                            target: NSDecimalNumber(decimal: rounded(test.target, scale: 0, roundingMode: .plain)).intValue
                        )
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
