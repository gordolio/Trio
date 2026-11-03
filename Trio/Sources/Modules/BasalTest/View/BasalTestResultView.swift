import SwiftUI

extension BasalTest {
    /// The result, in the order a reader needs it: the verdict, the docs' line behind it, the chart with its band, the
    /// working with the docs' 10% beside it, and then what the docs say to do next.
    struct ResultView: View {
        @Bindable var state: StateModel

        var body: some View {
            if let test = state.test, let outcome = test.outcome {
                let working = working(for: test, outcome: outcome)
                SettingsTestScreen(paintsBackground: false) {
                    header(for: outcome, test: test)

                    meaningCard(for: outcome, test: test)

                    chartCard(for: test)

                    // A low ends the fast at Trio's suspend, which is the point of this result. The suspend can come
                    // from Trio's forecast before glucose itself is low, so there is no working to show.
                    if test.endReason == .low, let suspendedAt = test.endedAt {
                        lowCard(at: suspendedAt)
                    } else if let working {
                        formulaCard(for: working)
                    }

                    nextCard(for: outcome, test: test)

                    if let smbs = state.smbCheck {
                        SettingsTestCard(title: String(localized: "Before the test")) {
                            SettingsTestValueRow(title: smbs.title, value: smbs.value ?? "", info: smbs.info)
                        }
                    }
                } footer: {
                    // Trio doesn't push changes and the docs say to wait several days, so Done is the main action.
                    Button("Done") { state.acknowledgeResult() }
                        .buttonStyle(.testPrimary)
                    if outcome == .rising || outcome == .falling {
                        Button("Open Basal Rates") { state.showModal(for: .basalProfileEditor) }
                            .buttonStyle(.testSecondary)
                    }
                }
            }
        }

        // MARK: - Header

        /// The verdict in the docs' terms, with what glucose did under it.
        private func header(for outcome: BasalTestOutcome, test: BasalTestState) -> some View {
            SettingsTestHeader(
                icon: icon(for: outcome),
                title: title(for: outcome, test: test),
                subtitle: observation(for: outcome, test: test),
                tint: tint(for: outcome)
            )
        }

        private func title(for outcome: BasalTestOutcome, test: BasalTestState) -> String {
            switch outcome {
            case .steady: return String(localized: "Basal looks right")
            case .rising: return String(localized: "Basal looks too low")
            case .falling: return String(localized: "Basal looks too high")
            case .inconclusive:
                // A fast that ran its hours but had no readings, or no history to check for a low, wasn't too short.
                let elapsed = (test.endedAt ?? test.plannedEnd).timeIntervalSince(test.startedAt)
                return elapsed < Config.docsShortestFast
                    ? String(localized: "Too soon to tell")
                    : String(localized: "Can't tell from this fast")
            case .invalid: return String(localized: "Test interrupted")
            }
        }

        /// "Glucose rose 30 mg/dL in 4 h".
        private func observation(for outcome: BasalTestOutcome, test: BasalTestState) -> String {
            let elapsed = elapsedText(for: test)
            guard outcome.isConclusive, let end = test.endGlucose else {
                if test.endReason == .low { return String(localized: "Trio suspended insulin for a low") }
                return String(localized: "Ended after \(elapsed)")
            }
            let net = end - test.startGlucose
            let amount = state.formatWithUnits(abs(net))
            if net > 0 { return String(localized: "Glucose rose \(amount) in \(elapsed)") }
            if net < 0 { return String(localized: "Glucose fell \(amount) in \(elapsed)") }
            return String(localized: "Glucose didn't move in \(elapsed)")
        }

        /// "4 h", or "2 h 10 m" when it isn't whole hours.
        private func elapsedText(for test: BasalTestState) -> String {
            let elapsed = (test.endedAt ?? test.plannedEnd).timeIntervalSince(test.startedAt)
            let minutes = Int(max(0, elapsed)) / 60
            return minutes % 60 == 0 && minutes > 0 ? "\(minutes / 60) h" : SettingsTestFormat.duration(elapsed)
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

        // MARK: - Meaning

        /// The docs' line first, in primary text, then one short sentence of the app's own.
        private func meaningCard(for outcome: BasalTestOutcome, test: BasalTestState) -> some View {
            let line = docsLine(for: outcome)
            return SettingsTestCard {
                if let line {
                    SettingsTestDocsQuote(text: line)
                }
                ForEach(Array(paragraphs(for: outcome, test: test).enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(line == nil ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        /// The docs' line for what the fast showed.
        private func docsLine(for outcome: BasalTestOutcome) -> String? {
            switch outcome {
            case .steady: return Docs.steadyGlucose
            case .rising: return Docs.risingGlucose
            case .falling: return Docs.fallingGlucose
            case .inconclusive,
                 .invalid: return nil
            }
        }

        private func paragraphs(for outcome: BasalTestOutcome, test: BasalTestState) -> [String] {
            let elapsed = (test.endedAt ?? test.plannedEnd).timeIntervalSince(test.startedAt)
            let evaluation = state.evaluation
            let noReadings = String(
                localized: "No CGM readings were recorded during the fast, so there is no end glucose to compare."
            )
            // With readings but no ISF or basal, so there is no rate or share to work out.
            let noWorking = String(
                localized: "Trio couldn't read your ISF or basal schedule for these hours, so there is no working to show."
            )
            let missingInputs = test.endGlucose != nil && (evaluation?.ratePerHour == nil || evaluation?.share == nil)
            // A low has no working on purpose: its own card says when Trio suspended.
            let missingWorking = missingInputs && test.endReason != .low
            switch outcome {
            case .steady:
                return [String(localized: "Glucose moved less than the docs' smallest basal change would explain.")]
            case .rising:
                return [String(localized: "A higher basal number gives more insulin.")] + (missingWorking ? [noWorking] : [])
            case .falling:
                return [String(localized: "A lower basal number gives less insulin.")]
                    + (test.endGlucose == nil ? [noReadings] : missingWorking ? [noWorking] : [])
            case .inconclusive:
                if test.endReason == .unchecked {
                    return [
                        String(localized: "Trio couldn't read the pump history to check for a low, so it can't judge this fast.")
                    ] + (test.endGlucose == nil ? [noReadings] : [])
                }
                if test.endGlucose == nil {
                    return [noReadings]
                }
                guard elapsed < Config.docsShortestFast else {
                    return [
                        String(
                            localized: "Trio couldn't read your ISF or basal schedule for these hours, so it can't tell what your basal did."
                        )
                    ]
                }
                return [
                    String(
                        localized: "The docs say to fast 4–6 hours, and this one ended after \(SettingsTestFormat.duration(elapsed)). That's too soon to trust."
                    )
                ] + (missingInputs ? [noWorking] : [])
            case .invalid:
                return [
                    test.interference
                        ?? String(localized: "Something changed during the fast, so the result can't be trusted. Try again.")
                ]
            }
        }

        // MARK: - Chart

        private func chartCard(for test: BasalTestState) -> some View {
            SettingsTestCard {
                SettingsTestMetricRow(metrics: [
                    SettingsTestMetric(title: String(localized: "Start"), value: state.format(test.startGlucose)),
                    SettingsTestMetric(title: String(localized: "End"), value: test.endGlucose.map(state.format) ?? "—"),
                    SettingsTestMetric(
                        title: String(localized: "Change"),
                        value: test.endGlucose.map { state.formatChange($0 - test.startGlucose) } ?? "—"
                    )
                ])

                // With nothing to draw, a line says so: an empty chart with a band would explain a band over no data.
                if test.readings.isEmpty {
                    Text("No CGM readings to chart.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    SettingsTestGlucoseChart(
                        points: test.readings.map { SettingsTestGlucosePoint(date: $0.date, glucose: $0.glucose) },
                        units: state.glucoseUnits,
                        band: state.resultBand
                    )
                }

                Text(window(for: test))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.resultBand != nil, !test.readings.isEmpty {
                    Text(
                        "Inside the green band, the change is smaller than the docs' smallest basal change (\(state.stepPercent)%)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func window(for test: BasalTestState) -> String {
            let start = test.startedAt.formatted(date: .omitted, time: .shortened)
            let end = (test.endedAt ?? test.plannedEnd).formatted(date: .omitted, time: .shortened)
            let reason: String
            switch test.endReason {
            case .low: reason = String(localized: ". Ended early: Trio suspended insulin for a low.")
            case .endedEarly: reason = String(localized: ". You ended it early.")
            case .interrupted: reason = String(localized: ". Ended early: it was interrupted.")
            case .completed,
                 nil,
                 .unchecked: reason = ""
            }
            return "\(start) – \(end)\(reason)"
        }

        // MARK: - Low

        private func lowCard(at suspendedAt: Date) -> some View {
            SettingsTestCard {
                Label {
                    Text("Trio suspended insulin for a low at \(suspendedAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }

        // MARK: - Working

        /// The numbers behind the result, as the formula card shows them.
        private struct Working {
            /// mg/dL
            let netChange: Int
            /// mg/dL per unit
            let isf: Decimal
            /// Units per hour
            let basal: Decimal
            let hours: Decimal
            /// Units per hour
            let rate: Decimal
            /// Of the basal
            let share: Decimal
        }

        /// Nil when there is nothing to show: no ISF, basal or readings to work from, or a fast that was
        /// interrupted or ended too soon to say anything about the basal.
        private func working(for test: BasalTestState, outcome: BasalTestOutcome) -> Working? {
            guard outcome.isConclusive,
                  let evaluation = state.evaluation,
                  let rate = evaluation.ratePerHour,
                  let share = evaluation.share,
                  let isf = test.isf,
                  let basal = state.resultBasal,
                  let hours = state.resultHours
            else { return nil }
            return Working(netChange: evaluation.netChange, isf: isf, basal: basal, hours: hours, rate: rate, share: share)
        }

        /// Change ÷ ISF ÷ Hours = rate, then rate ÷ basal = share, with the user's own settings in blue, and under it
        /// the share against the docs' smallest change, which is what decides the result.
        private func formulaCard(for working: Working) -> some View {
            let units = state.glucoseUnits
            let rate = state.formatSigned(working.rate, fractionDigits: 2)
            let ratePerHour = String(localized: "units per hour")

            let change = SettingsTestFormulaTerm(
                label: String(localized: "Change"),
                value: state.formatChange(working.netChange),
                unit: units.rawValue,
                fromSettings: false
            )
            let isf = SettingsTestFormulaTerm(
                label: String(localized: "ISF"),
                value: state.formatISF(working.isf),
                unit: "\(units.rawValue)/U",
                fromSettings: true
            )
            let hours = SettingsTestFormulaTerm(
                label: String(localized: "Hours"),
                value: working.hours.formatted(.number.precision(.fractionLength(0 ... 2))),
                unit: "h",
                fromSettings: false,
                spokenUnit: String(localized: "hours")
            )
            // The rate and the share are rounded toward zero for display, so each follows "≈": worked out from the shown
            // numbers they can be a percent apart. The verdict and the comparison under the card use the exact share.
            let rateTerm = SettingsTestFormulaTerm(
                label: String(localized: "Rate"),
                value: rate,
                unit: "U/h",
                fromSettings: false,
                spokenUnit: ratePerHour,
                approximate: true
            )
            let basal = SettingsTestFormulaTerm(
                label: String(localized: "Basal"),
                value: working.basal.formatted(.number.precision(.fractionLength(2))),
                unit: String(localized: "U/h avg"),
                fromSettings: true,
                spokenUnit: String(localized: "units per hour, on average")
            )

            let rows: [[SettingsTestFormulaPart]] = [
                [.term(change), .op("÷"), .term(isf), .op("÷"), .term(hours)],
                [.term(rateTerm), .op("÷"), .term(basal)]
            ]
            let results = [
                rateTerm,
                SettingsTestFormulaTerm(
                    label: String(localized: "Share"),
                    value: state.formatPercent(working.share),
                    unit: String(localized: "of basal"),
                    fromSettings: false,
                    approximate: true
                )
            ]
            return SettingsTestFormulaCard(
                title: String(localized: "How Trio worked this out"),
                rows: rows,
                result: results,
                conclusion: comparison(for: working.share)
            )
        }

        /// "18% is more than the docs' smallest change (10%)", from the share as shown, so it always agrees with the
        /// verdict. A size against a size, so a fall reads without its minus sign.
        private func comparison(for share: Decimal) -> Text {
            let shown = abs(BasalTestEvaluator.wholePercent(share))
            let percent = Text(verbatim: "\(shown.formatted())%").bold()
            let step = state.stepPercent
            if shown < step {
                return Text("\(percent) is less than the docs' smallest change (\(step)%).")
            }
            if shown == step {
                return Text("\(percent) is the docs' smallest change (\(step)%).")
            }
            return Text("\(percent) is more than the docs' smallest change (\(step)%).")
        }

        // MARK: - Next

        /// What the docs say about changing basal, for a result that says something, and the pages behind the result.
        private func nextCard(for outcome: BasalTestOutcome, test: BasalTestState) -> some View {
            SettingsTestCard {
                switch outcome {
                case .falling,
                     .rising:
                    SettingsTestDocsQuote(text: "\(Docs.gradualAdjustments)\n\(Docs.waitBetweenAdjustments)")
                    if let spans = coveredSpans(for: test) {
                        Text("This test covered \(spans).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .steady:
                    SettingsTestDocsQuote(text: Docs.waitBetweenAdjustments)
                case .inconclusive,
                     .invalid:
                    EmptyView()
                }

                SettingsTestDocsLinks(
                    links: outcome.isConclusive
                        ? [Docs.fastingTestsLink, Docs.adjustingBasalLink]
                        : [Docs.fastingTestsLink]
                )
            }
        }

        /// The schedule entries the hours the test ran covered, e.g. "12:00 AM–6:00 AM".
        private func coveredSpans(for test: BasalTestState) -> String? {
            guard let end = test.endedAt,
                  let entries = BasalTestEvaluator.coveredEntries(for: test, endingAt: end)
            else { return nil }
            return entries.map { SettingsTestSchedule.spanText(of: $0) }.formatted(.list(type: .and))
        }
    }
}
