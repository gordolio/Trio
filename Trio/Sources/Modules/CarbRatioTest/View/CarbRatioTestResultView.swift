import SwiftUI

extension CarbRatioTest {
    /// The result, in the order a reader needs it: the verdict, the docs' line behind it, the chart with its band, the
    /// working against the carb ratio and the docs' 1 g/U, the tablets, and then what the docs say to do next. It only
    /// shows the result: the finish already archived a verdict, and a result never changes a setting.
    struct ResultView: View {
        @Bindable var state: StateModel

        var body: some View {
            if let test = state.test, let outcome = test.outcome {
                let noVerdict = state.noVerdict
                SettingsTestScreen(paintsBackground: false) {
                    SettingsTestHeader(
                        icon: icon(for: outcome),
                        title: CarbRatioTestEvaluator.headline(for: outcome, noVerdict: noVerdict),
                        subtitle: observation(for: outcome, test: test),
                        tint: tint(for: outcome)
                    )

                    meaningCard(for: outcome, test: test, noVerdict: noVerdict)

                    chartCard(for: test)

                    // A low ends the test at Trio's suspend, which is the point of this result, so it isn't judged on
                    // where glucose ended and there is no working to show.
                    if state.showsLowCard {
                        lowCard
                    } else if test.endReason != .low, let working = working(for: test) {
                        formulaCard(for: working)
                    }

                    if test.bolusAt != nil {
                        tabletsCard(for: test)
                    }

                    // The usual dosing didn't come back: no test runs Basal Testing now, so the screen doesn't say it did.
                    if state.basalTestingLeftOn {
                        basalTestingCard
                    }

                    nextCard(for: outcome, test: test)
                } footer: {
                    // Trio doesn't change settings and the docs say to wait days between changes, so Done is the main
                    // action.
                    Button("Done") { state.acknowledgeResult() }
                        .buttonStyle(.testPrimary)
                    if state.offersCarbRatios {
                        // The hub opens this screen while another test runs; a carb ratio change now would throw that
                        // test off.
                        if let running = state.otherRunningTest {
                            Text(
                                "Change your carb ratio once the \(running.title) test ends, so that test checks one setting at a time."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Button("Open Carb Ratios") { state.showModal(for: .crEditor) }
                                .buttonStyle(.testSecondary)
                        }
                    }
                }
            }
        }

        // MARK: - Header

        /// "Glucose ended 18 mg/dL higher than it started, on 4.00 U for 40 g", or for a low when Trio suspended insulin.
        private func observation(for outcome: CarbRatioTestOutcome, test: CarbRatioTestState) -> String {
            // Not for a forecast suspend, which isn't a low: it falls through to the lines of a test with no verdict.
            if let suspended = state.lowSuspendObservation {
                return suspended
            }
            guard outcome.isConclusive, let start = test.startGlucose, let end = test.endGlucose,
                  let given = state.unitsGivenText, let carbs = CarbRatioTestEvaluator.judgedCarbs(of: test)
            else {
                return String(localized: "Ended after \(CarbRatioTestEvaluator.elapsedText(for: test))")
            }
            let change = end - start
            let amount = state.formatWithUnits(abs(change))
            let grams = SettingsTestFormat.keepTogether(state.formatGrams(carbs), unit: "g")
            if change > 0 { return String(localized: "Glucose ended \(amount) higher than it started, on \(given) for \(grams)") }
            if change < 0 { return String(localized: "Glucose ended \(amount) lower than it started, on \(given) for \(grams)") }
            return String(localized: "Glucose ended where it started, on \(given) for \(grams)")
        }

        /// The icon carries the change the docs say to make: down for a carb ratio that looks too high (DECREASE), up for
        /// one that looks too low or ended in a low (INCREASE).
        private func icon(for outcome: CarbRatioTestOutcome) -> String {
            switch outcome {
            case .accurate: return "checkmark.circle.fill"
            case .tooHigh: return "arrow.down.circle.fill"
            case .tooLow: return "arrow.up.circle.fill"
            case .inconclusive: return "questionmark.circle.fill"
            case .invalid: return "exclamationmark.triangle.fill"
            }
        }

        private func tint(for outcome: CarbRatioTestOutcome) -> Color {
            switch outcome {
            case .accurate: return .green
            case .tooHigh,
                 .tooLow: return .orange
            case .inconclusive: return .secondary
            case .invalid: return .red
            }
        }

        // MARK: - Meaning

        /// The docs' line first, in primary text, then one short paragraph of the app's own.
        private func meaningCard(
            for outcome: CarbRatioTestOutcome,
            test: CarbRatioTestState,
            noVerdict: CarbRatioTestNoVerdict?
        ) -> some View {
            let line = CarbRatioTestEvaluator.docsLine(for: outcome, noVerdict: noVerdict)
            return SettingsTestCard {
                // Trio's suspend for a low ended the test before its length was up. The suspend can come from Trio's
                // forecast, so it isn't worded as glucose going low.
                if outcome == .tooLow, test.endReason == .low {
                    Text("Trio suspended insulin for a low before the \(state.lengthText(test.length)) were up.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line {
                    SettingsTestDocsQuote(text: line)
                }
                Text(paragraph(for: outcome, test: test, noVerdict: noVerdict))
                    .font(.subheadline)
                    .foregroundStyle(line == nil ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = expectedEndNote(for: test) {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        /// The docs speak of returning to the starting glucose, but a bolus other than the formula's for the carbs logged
        /// doesn't aim there, so where an accurate carb ratio would have taken glucose is said beside them.
        private func expectedEndNote(for test: CarbRatioTestState) -> String? {
            guard let expected = state.expectedEndAwayFromStart,
                  let judged = CarbRatioTestEvaluator.judgedUnits(of: test),
                  let carbs = CarbRatioTestEvaluator.judgedCarbs(of: test)
            else { return nil }
            let end = SettingsTestFormat.keepTogether(state.formatTarget(expected), unit: state.glucoseUnits.rawValue)
            let units = SettingsTestFormat.keepTogether(state.formatUnits(judged), unit: "U")
            let grams = SettingsTestFormat.keepTogether(state.formatGrams(carbs), unit: "g")
            return String(
                localized: "With \(units) acting for \(grams), glucose would end near \(end) if your carb ratio were right, so the test compares the ratio they show with yours, not where glucose ended."
            )
        }

        /// The docs speak of glucose returning to where it started; the test judges the carbs against the insulin that
        /// acted, so a bolus other than the formula's still tests the carb ratio. A result with no verdict says why.
        private func paragraph(
            for outcome: CarbRatioTestOutcome,
            test: CarbRatioTestState,
            noVerdict: CarbRatioTestNoVerdict?
        ) -> String {
            let higherRatio = String(localized: "A higher carb ratio number gives less insulin for the same carbs.")
            switch outcome {
            case .accurate:
                return String(
                    localized: "The carbs and the insulin that acted show a carb ratio within \(state.stepText) of yours."
                )
            case .tooHigh:
                return String(
                    localized: "The carbs needed more insulin than your carb ratio gives. A lower carb ratio number gives more insulin for the same carbs."
                )
            case .tooLow:
                if test.endReason == .low { return higherRatio }
                return String(localized: "The carbs needed less insulin than your carb ratio gives.") + " " + higherRatio
            case .inconclusive,
                 .invalid:
                let text = CarbRatioTestEvaluator.noVerdictText(noVerdict, test: test)
                // With Basal Testing on, left on or another test's, it doesn't say the usual dosing is back.
                return CarbRatioTestEvaluator
                    .modeWorded(text, modeBack: state.usualModeIsOn, usualMode: test.previousMode) ?? text
            }
        }

        // MARK: - Chart

        private func chartCard(for test: CarbRatioTestState) -> some View {
            let band = state.resultBand
            return SettingsTestCard {
                // With nothing to draw, a line says so: an empty chart with a band would explain a band over no data.
                if test.readings.isEmpty {
                    Text("No CGM readings to chart.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    SettingsTestGlucoseChart(
                        points: test.readings.map { SettingsTestGlucosePoint(date: $0.date, glucose: $0.glucose) },
                        units: state.glucoseUnits,
                        band: band,
                        target: NSDecimalNumber(decimal: rounded(test.target, scale: 0, roundingMode: .plain)).intValue,
                        // Where glucose should be once the length is up, not along the way.
                        bandTimes: state.resultBandTimes
                    )
                }

                Text(window(for: test))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if band != nil, !test.readings.isEmpty {
                    Text(
                        "The band is where glucose would end if your carb ratio were right to within \(state.stepText) either way, from the insulin that acted by the end."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The insulin left at the end hadn't acted, so glucose would still move after it.
                    if let line = state.stillToComeOffLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        /// The hours the chart covers, from the bolus (from Begin if none came), and why it ended early.
        private func window(for test: CarbRatioTestState) -> String {
            let start = (test.bolusAt ?? test.startedAt).formatted(date: .omitted, time: .shortened)
            let end = (test.endedAt ?? test.plannedEnd ?? test.doseDeadline).formatted(date: .omitted, time: .shortened)
            return "\(start) – \(end)\(state.endedEarlyCaption)"
        }

        // MARK: - Mode

        private var basalTestingCard: some View {
            SettingsTestCard {
                Label {
                    Text("Basal Testing is still on. Switch back to your usual dosing mode in Settings.")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }

        // MARK: - Low

        private var lowCard: some View {
            SettingsTestCard {
                Label {
                    Text("Treat the low as usual.")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }

        // MARK: - Working

        /// The numbers behind the result, as the formula card shows them.
        private struct Working {
            /// mg/dL
            let start: Int
            /// mg/dL
            let end: Int
            /// The bolus, as the pump history holds it.
            let bolus: Decimal
            /// The insulin on board at the bolus the units counted, signed. Nil when there is none to show.
            let onBoard: Decimal?
            /// The insulin Trio reported still on board at the end of the chosen length, signed, which hadn't acted.
            let left: Decimal
            /// The units judged by: the bolus, with the insulin on board counted, less what was left at the end.
            let units: Decimal
            /// Grams logged with the bolus.
            let carbs: Decimal
            /// mg/dL per unit, in force at the bolus.
            let isf: Decimal
            /// Grams per unit, in force at the bolus.
            let carbRatio: Decimal
            /// The glucose change turned into units, (end − start) ÷ ISF, signed.
            let change: Decimal
            /// Grams per unit the test showed. Nil when the insulin comes to zero or less.
            let shownRatio: Decimal?
        }

        /// Nil when the result isn't judged on where glucose ended (a low, or no verdict), or when working it out again
        /// doesn't give the verdict the headline shows.
        private func working(for test: CarbRatioTestState) -> Working? {
            guard let evaluation = state.evaluation, evaluation.outcome.isConclusive,
                  let start = test.startGlucose,
                  let end = test.endGlucose,
                  let bolus = test.bolusUnits,
                  let left = test.iobAtEnd,
                  let units = CarbRatioTestEvaluator.judgedUnits(of: test),
                  let carbs = CarbRatioTestEvaluator.judgedCarbs(of: test),
                  test.isf > 0
            else { return nil }
            return Working(
                start: start,
                end: end,
                bolus: bolus,
                onBoard: state.shownIOBAtBolus,
                left: left,
                units: units,
                carbs: carbs,
                isf: test.isf,
                carbRatio: test.carbRatio,
                change: Decimal(end - start) / test.isf,
                shownRatio: evaluation.shownRatio
            )
        }

        /// Bolus − Left = Units (with insulin on board at the bolus, Bolus + On board − Left), then (End − Start) ÷ ISF =
        /// Change, the units the glucose change stands for, then Carbs ÷ (Units + Change) = the ratio the test showed, then
        /// Ratio − CR = how far off it is, with the ISF and the carb ratio in blue because they are the user's settings, and
        /// under it the docs' smallest change, which decides the result. Each on a line of its own, so it fits a small phone.
        private func formulaCard(for working: Working) -> some View {
            let units = state.glucoseUnits.rawValue
            func term(_ label: String, _ value: String, _ unit: String, settings: Bool = false, approximate: Bool = false)
                -> SettingsTestFormulaTerm
            {
                SettingsTestFormulaTerm(
                    label: label,
                    value: value,
                    unit: unit,
                    fromSettings: settings,
                    approximate: approximate
                )
            }
            var rows: [[SettingsTestFormulaPart]] = []
            var results: [SettingsTestFormulaTerm] = []

            // Bolus (+ On board) − Left = Units. Each amount is shown to 2 decimals, so the units follow "≈" when any of
            // them had more.
            let amounts = [working.bolus, working.left, working.units] + (working.onBoard.map { [$0] } ?? [])
            let given = term(
                String(localized: "Units"),
                state.formatUnits(working.units),
                "U",
                approximate: amounts.contains { rounded($0, scale: 2, roundingMode: .plain) != $0 }
            )
            var unitsRow: [SettingsTestFormulaPart] =
                [.term(term(String(localized: "Bolus"), state.formatUnits(working.bolus), "U"))]
            if let onBoard = working.onBoard {
                let label = onBoard < 0 ? String(localized: "Held back") : String(localized: "On board")
                unitsRow += [.op(onBoard < 0 ? "−" : "+"), .term(term(label, state.formatUnits(abs(onBoard)), "U"))]
            }
            // "Left", short, so the row fits a small phone: on board at the end of the chosen length.
            unitsRow += [
                .op(working.left < 0 ? "+" : "−"),
                .term(term(String(localized: "Left"), state.formatUnits(abs(working.left)), "U"))
            ]
            rows.append(unitsRow)
            results.append(given)

            // (End − Start) ÷ ISF = Change, in units, signed.
            // "≈" when the units have more than 2 decimals, or are worked out from values shown in mmol/L.
            let change = term(
                String(localized: "Change"),
                state.formatSignedUnits(working.change),
                "U",
                approximate: ISFTestEvaluator.isApproximate(working.change, fractionDigits: 2, units: state.glucoseUnits)
            )
            rows.append([
                .op("("),
                .term(term(String(localized: "End"), state.format(working.end), units)),
                .op("−"),
                .term(term(String(localized: "Start"), state.format(working.start), units)),
                .op(")"),
                .op("÷"),
                .term(term(String(localized: "ISF"), state.formatISF(working.isf), "\(units)/U", settings: true))
            ])
            results.append(change)

            let carbs = term(String(localized: "Carbs"), state.formatGrams(working.carbs), "g")
            let changeSize = term(String(localized: "Change"), state.formatUnits(abs(working.change)), "U")
            let ratioRow: [SettingsTestFormulaPart] = [
                .term(carbs), .op("÷"), .op("("), .term(given), .op(working.change < 0 ? "−" : "+"), .term(changeSize), .op(")")
            ]
            let carbRatio = term(String(localized: "CR"), state.formatCarbRatio(working.carbRatio), "g/U", settings: true)
            guard let shown = working.shownRatio else {
                // Glucose fell by at least what the insulin alone explains: more insulin than the carbs needed.
                return SettingsTestFormulaCard(
                    title: String(localized: "How Trio worked this out"),
                    rows: rows,
                    result: results,
                    conclusion: Text(
                        "Glucose fell by at least what the insulin alone explains, so the carbs needed less insulin than your carb ratio of \(state.formatCarbRatio(working.carbRatio)) g/U gives."
                    )
                )
            }
            // Both results are rounded for display, so each follows "≈". The verdict uses the exact ratio.
            let ratio = term(String(localized: "Ratio"), state.formatCarbRatio(shown), "g/U", approximate: true)
            rows.append(ratioRow)
            results.append(ratio)
            let difference = term(
                String(localized: "Off by"),
                (shown - working.carbRatio < 0 ? "\u{2212}" : "+") + state.formatCarbRatio(abs(shown - working.carbRatio)),
                "g/U",
                approximate: true
            )
            rows.append([.term(ratio), .op("−"), .term(carbRatio)])
            results.append(difference)
            return SettingsTestFormulaCard(
                title: String(localized: "How Trio worked this out"),
                rows: rows,
                result: results,
                conclusion: Text("The smallest change in Trio docs is \(state.stepText).")
            )
        }

        // MARK: - Tablets

        /// "10 tablets of Dex4 (40 g), logged as 40 g with the bolus".
        private func tabletsCard(for test: CarbRatioTestState) -> some View {
            let brand = test.brand?.displayName ?? test.tabletBrand
            let grams = SettingsTestFormat.keepTogether(state.formatGrams(test.tabletCarbs), unit: "g")
            let tablets = test.tabletCount == 1
                ? String(localized: "1 tablet of \(brand) (\(grams))")
                : String(localized: "\(test.tabletCount) tablets of \(brand) (\(grams))")
            let logged: String
            if let carbs = test.carbs {
                let loggedGrams = SettingsTestFormat.keepTogether(state.formatGrams(carbs), unit: "g")
                if carbs == test.tabletCarbs {
                    logged = String(localized: "\(tablets), logged as \(loggedGrams) with the bolus.")
                } else if state.evaluation != nil {
                    // Within a gram, the entry field's rounding: the result is judged on what was eaten.
                    logged = String(
                        localized: "\(tablets). \(loggedGrams) logged with the bolus; the result uses the tablets' \(grams)."
                    )
                } else {
                    logged = String(localized: "\(tablets). \(loggedGrams) logged with the bolus.")
                }
            } else {
                logged = String(localized: "\(tablets). Their carbs weren't logged with the bolus.")
            }
            return SettingsTestCard {
                Text(logged)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // MARK: - Next

        /// What the docs say about changing the carb ratio, for a result that says something, and the pages behind it.
        private func nextCard(for outcome: CarbRatioTestOutcome, test: CarbRatioTestState) -> some View {
            SettingsTestCard {
                switch outcome {
                case .tooHigh,
                     .tooLow:
                    SettingsTestDocsQuote(text: "\(Docs.smallChanges)\n\(Docs.oneMealAtATime)\n\(Docs.waitBetweenChanges)")
                    if let spans = coveredSpans(for: test) {
                        Text("This test covered \(spans).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .accurate:
                    SettingsTestDocsQuote(text: Docs.waitBetweenChanges)
                case .inconclusive,
                     .invalid:
                    EmptyView()
                }

                SettingsTestDocsLinks(
                    links: outcome.isConclusive
                        ? [Docs.testingMethodLink, Docs.bestPracticesLink]
                        : [Docs.testingMethodLink]
                )
            }
        }

        /// The carb ratio schedule entry the test covered, fixed at the bolus as its record keeps it.
        private func coveredSpans(for test: CarbRatioTestState) -> String? {
            guard test.bolusAt != nil, let entries = test.crEntries, !entries.isEmpty else { return nil }
            return entries.map { SettingsTestSchedule.spanText(of: $0, inSentence: true) }.formatted(.list(type: .and))
        }
    }
}
