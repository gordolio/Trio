import SwiftUI

extension CarbRatioTest {
    /// The chosen 3 or 4 hours after the bolus: the time left, the tablets' carbs while they aren't logged yet, what ends
    /// the test, and glucose since the bolus.
    struct WaitView: View {
        @Bindable var state: StateModel

        var body: some View {
            // Minutes are all a wait of hours needs, so the countdown ticks once a minute.
            TimelineView(.everyMinute) { context in
                SettingsTestScreen(paintsBackground: false) {
                    countdown(now: context.date)
                    if let until = state.carbsAwaitedUntil {
                        carbsCard(until: until, now: context.date)
                    }
                    // What ends the test comes before the chart, so it is on screen without scrolling.
                    rulesCard
                    glucoseCard
                } footer: {
                    Button("End Test") { state.showStopOptions = true }
                        .buttonStyle(.testSecondary)
                        // Off while the test ends.
                        .disabled(state.isEnding)
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

        /// How long until the chosen length is up, and the bolus it runs from.
        private func countdown(now: Date) -> some View {
            let end = state.test?.plannedEnd ?? now
            let length = state.test?.length ?? Config.defaultLength
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
                    SettingsTestProgressBar(progress: 1 - remaining / length)
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

        /// "Bolus 4.00 U for 40 g at 2:20 PM", without the units when the pump recorded none, without the carbs before
        /// they are logged, and with the insulin on board at it the units count, once it has been read.
        private var bolusText: String? {
            guard let test = state.test, let bolusAt = test.bolusAt else { return nil }
            let time = bolusAt.formatted(date: .omitted, time: .shortened)
            let bolus: String
            switch (test.bolusUnits, test.carbs) {
            case let (units?, carbs?):
                bolus = String(localized: "Bolus \(state.formatUnits(units)) U for \(state.formatGrams(carbs)) g at \(time)")
            case let (units?, nil):
                bolus = String(localized: "Bolus \(state.formatUnits(units)) U at \(time)")
            case (nil, _):
                bolus = String(localized: "Bolus at \(time)")
            }
            guard let iob = state.shownIOBAtBolus else { return bolus }
            // The amount stays with its unit and "on board" stays together; the line can still break between the rest.
            let amount = SettingsTestFormat.keepTogether(state.formatSignedUnits(iob), unit: "U")
            let counted = String(localized: "\(amount) on board counted")
                .replacingOccurrences(of: "on board", with: "on\u{00A0}board")
            return bolus + " · " + counted
        }

        /// Shown while the tablets' carbs aren't logged yet: the test reads them from the entry logged with the bolus, and
        /// ends without a result if none comes within the meal's 15 minutes. They are logged with no other bolus, and
        /// Treatments opens with nothing filled in: Trio's Recommendation for them would suggest a second bolus, which
        /// ends the test.
        private func carbsCard(until: Date, now: Date) -> some View {
            let grams = state.test.map { SettingsTestFormat.keepTogether(state.formatGrams($0.tabletCarbs), unit: "g") } ?? ""
            let time = until.formatted(date: .omitted, time: .shortened)
            let current = max(now, Date())
            let minutes = state.carbsMinutesLeft(at: current) ?? 0
            // Past the 15 minutes the test is ending: no button that does nothing, and the card says so.
            let timeUp = until <= current
            return SettingsTestCard {
                Label {
                    if timeUp {
                        let pairing = Int(Config.mealPairing / 60)
                        Text("The \(pairing) minutes for the tablets' carbs are up, so the test is ending.")
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The tablets' carbs aren't logged yet. Log their \(grams) in Treatments without another bolus.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline.weight(.semibold))
                if !timeUp {
                    Text(
                        "Leave the bolus at 0: another bolus ends the test. \(minutes) min left, until \(time), or the test ends without a result."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Open Treatments") { state.openTreatmentsForCarbs() }
                        .buttonStyle(.testSecondary)
                        .disabled(state.isEnding)
                }
            }
        }

        /// The low comes first: it is the one thing to act on during the wait. Red is kept for it, and the other rules use
        /// a neutral glyph, so they don't look like a failed check.
        private var rulesCard: some View {
            SettingsTestCard(title: String(localized: "During the test")) {
                SettingsTestDocsQuote(text: "\(Docs.monitor)\n\(Docs.avoidFood)")
                rule(
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red),
                    "If Trio suspends insulin for a low, the test ends: treat the low as usual.",
                    emphasized: true
                )
                // Logged, food or a treated low ends the test; unlogged, it would read as the carb ratio.
                rule(
                    Image(systemName: "nosign").foregroundStyle(.secondary),
                    "If you eat anything else or treat a low, log it. The test then ends without a result, so it can't mislead you."
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
                    // "--" once the newest reading is out of date: the warning under the chart says why.
                    let now = state.glucoseNow
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
