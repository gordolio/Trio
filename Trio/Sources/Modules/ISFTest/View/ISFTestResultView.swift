import SwiftUI

extension ISFTest {
    /// The result, in the order a reader needs it: the verdict, the docs' line behind it, the chart with its band, the
    /// working with the docs' 5% beside it, and then what the docs say to do next. It only shows the result: the finish
    /// already archived a verdict, and a result never changes a setting.
    struct ResultView: View {
        @Bindable var state: StateModel

        var body: some View {
            if let test = state.test, let outcome = test.outcome {
                let noVerdict = state.noVerdict
                SettingsTestScreen(paintsBackground: false) {
                    header(for: outcome, test: test, noVerdict: noVerdict)

                    meaningCard(for: outcome, test: test, noVerdict: noVerdict)

                    chartCard(for: test)

                    // A low ends the test at Trio's suspend, which is the point of this result, so it isn't judged on
                    // the drop and there is no working to show.
                    if test.endReason == .low {
                        lowCard
                    } else if let working = working(for: test) {
                        formulaCard(for: working)
                    }

                    if let tablets = state.resultTablets {
                        tabletsCard(tablets)
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
                    if outcome == .tooHigh || outcome == .tooLow {
                        Button("Open Insulin Sensitivities") { state.showModal(for: .isfEditor) }
                            .buttonStyle(.testSecondary)
                    }
                }
            }
        }

        // MARK: - Header

        /// The verdict in the docs' terms, with what glucose did under it. The icon carries the change the docs say to
        /// make, as the basal result's does and as the archived direction and the share's sign do: down for an ISF that
        /// looks too high (DECREASE), up for one that looks too low or ended in a low (INCREASE).
        private func header(for outcome: ISFTestOutcome, test: ISFTestState, noVerdict: ISFTestNoVerdict?) -> some View {
            SettingsTestHeader(
                icon: icon(for: outcome),
                title: title(for: outcome, noVerdict: noVerdict),
                subtitle: observation(for: outcome, test: test),
                tint: tint(for: outcome)
            )
        }

        private func title(for outcome: ISFTestOutcome, noVerdict: ISFTestNoVerdict?) -> String {
            switch outcome {
            case .accurate: return String(localized: "ISF looks accurate")
            case .tooHigh: return String(localized: "ISF looks too high")
            case .tooLow: return String(localized: "ISF looks too low")
            case .inconclusive:
                // A test that ran its 4 hours but couldn't be checked, or had nothing to compare, wasn't too short.
                return noVerdict == .tooSoon
                    ? String(localized: "Too soon to tell")
                    : String(localized: "Can't tell from this test")
            case .invalid: return String(localized: "Test was interrupted")
            }
        }

        /// "Glucose dropped 112 mg/dL on 2.24 U", or for a low when Trio suspended insulin. In a test that counted insulin
        /// on board, both amounts, "on 2.00 U plus 0.24 U on board" (`ISFTestEvaluator.unitsText`).
        private func observation(for outcome: ISFTestOutcome, test: ISFTestState) -> String {
            if test.endReason == .low, let suspendedAt = test.endedAt {
                return String(
                    localized: "Trio suspended insulin for a low at \(suspendedAt.formatted(date: .omitted, time: .shortened))"
                )
            }
            guard outcome.isConclusive, let start = test.startGlucose, let end = test.endGlucose,
                  let given = ISFTestEvaluator.unitsText(of: test, format: state.formatUnits)
            else {
                return String(localized: "Ended after \(elapsedText(for: test))")
            }
            let drop = start - end
            let amount = state.formatWithUnits(abs(drop))
            if drop > 0 { return String(localized: "Glucose dropped \(amount) on \(given)") }
            if drop < 0 { return String(localized: "Glucose rose \(amount) on \(given)") }
            return String(localized: "Glucose didn't move on \(given)")
        }

        /// From the bolus, or from Start if none came, to the end.
        private func elapsed(for test: ISFTestState) -> TimeInterval {
            let end = test.endedAt ?? test.plannedEnd ?? test.doseDeadline
            return max(0, end.timeIntervalSince(test.bolusAt ?? test.startedAt))
        }

        /// "4 h", or "2 h 10 m" when it isn't whole hours.
        private func elapsedText(for test: ISFTestState) -> String {
            let elapsed = elapsed(for: test)
            let minutes = Int(elapsed) / 60
            return minutes % 60 == 0 && minutes > 0 ? "\(minutes / 60) h" : SettingsTestFormat.duration(elapsed)
        }

        private func icon(for outcome: ISFTestOutcome) -> String {
            switch outcome {
            case .accurate: return "checkmark.circle.fill"
            case .tooHigh: return "arrow.down.circle.fill"
            case .tooLow: return "arrow.up.circle.fill"
            case .inconclusive: return "questionmark.circle.fill"
            case .invalid: return "exclamationmark.triangle.fill"
            }
        }

        private func tint(for outcome: ISFTestOutcome) -> Color {
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
            for outcome: ISFTestOutcome,
            test: ISFTestState,
            noVerdict: ISFTestNoVerdict?
        ) -> some View {
            let line = docsLine(for: outcome, noVerdict: noVerdict)
            return SettingsTestCard {
                // The docs' line speaks of 4 hours, and Trio's suspend for a low ended the test before them. The suspend can
                // come from Trio's forecast, so it isn't worded as glucose going low.
                if outcome == .tooLow, test.endReason == .low {
                    Text("Trio suspended insulin for a low before the 4 hours were up.")
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

        /// The docs' line and the chart's target line speak of ending at target, but a dose other than the docs' doesn't
        /// aim there, so where an accurate ISF would have taken glucose is said beside them.
        private func expectedEndNote(for test: ISFTestState) -> String? {
            guard let expected = state.expectedEndAwayFromTarget,
                  let judged = ISFTestEvaluator.judgedUnits(of: test)
            else { return nil }
            let end = SettingsTestFormat.keepTogether(state.formatTarget(expected), unit: state.glucoseUnits.rawValue)
            let units = SettingsTestFormat.keepTogether(state.formatUnits(judged), unit: "U")
            return String(
                localized: "With \(units) acting in the 4 hours, glucose would end near \(end) if your ISF were right, so the test compares the drop per unit with your ISF, not where glucose ended."
            )
        }

        /// The docs' line for what the test showed. A test that ended before the 4 hours gets the docs' wait instead.
        private func docsLine(for outcome: ISFTestOutcome, noVerdict: ISFTestNoVerdict?) -> String? {
            switch outcome {
            case .accurate: return Docs.atTarget
            case .tooHigh: return Docs.stillAboveTarget
            case .tooLow: return Docs.belowTarget
            case .inconclusive: return noVerdict == .tooSoon ? Docs.waitFourHours : nil
            case .invalid: return nil
            }
        }

        /// The docs speak of ending at target; the test judges each unit given, so a dose smaller or larger than the
        /// docs' still tests the ISF. A result with no verdict says why.
        private func paragraph(for outcome: ISFTestOutcome, test: ISFTestState, noVerdict: ISFTestNoVerdict?) -> String {
            let higherISF = String(localized: "A higher ISF number gives less insulin for each correction.")
            switch outcome {
            case .accurate:
                return String(localized: "For each unit that acted in the 4 hours, glucose fell by about your ISF.")
            case .tooHigh:
                return String(
                    localized: "For each unit that acted in the 4 hours, glucose didn't fall as much as your ISF. A lower ISF number gives more insulin for each correction."
                )
            case .tooLow:
                if test.endReason == .low { return higherISF }
                return String(localized: "For each unit that acted in the 4 hours, glucose fell more than your ISF.") + " " +
                    higherISF
            case .inconclusive,
                 .invalid:
                return whyNoVerdict(noVerdict, test: test)
            }
        }

        private func whyNoVerdict(_ noVerdict: ISFTestNoVerdict?, test: ISFTestState) -> String {
            switch noVerdict {
            case .noBolus:
                let minutes = Int(Config.doseAllowance / 60)
                return String(
                    localized: "The test needs your bolus within \(minutes) minutes of starting. Trio didn't see one, so there was nothing to judge."
                )
            case .interrupted:
                return test.interference
                    ?? String(localized: "Something changed during the test, so the result can't be trusted. Try again.")
            case .historyUnread:
                return ISFTestEvaluator.historyUnreadNote
            case .tooSoon:
                return String(
                    localized: "This test ended after \(elapsedText(for: test)), so it's too soon to tell what your ISF did."
                )
            case .lowUnchecked:
                return String(localized: "Trio couldn't read the pump history to check for a low, so it can't judge this test.")
            case .noReadings:
                return String(
                    localized: "No CGM readings were recorded at the bolus or at the end of the test, so there is nothing to compare."
                )
            case .noAmount:
                return String(
                    localized: "The pump didn't record how much insulin the bolus gave, so there is no drop per unit to work out."
                )
            case .doseTooSmall:
                return String(localized: "The dose was too small for this test to tell your ISF apart from CGM noise.")
            case .forecastSuspend:
                return String(
                    localized: "Trio suspended insulin on its forecast while your glucose was still above your target, so the test can't tell."
                )
            case .doseOverDocs:
                return String(localized: "The bolus was more than the docs' dose, so the low can't be put down to your ISF.")
            case nil:
                return String(localized: "Trio couldn't tell what your ISF did from this test.")
            }
        }

        // MARK: - Chart

        private func chartCard(for test: ISFTestState) -> some View {
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
                        // The expected end is where glucose should be once the 4 hours are up, not along the way.
                        bandTimes: state.resultBandTimes
                    )
                }

                Text(window(for: test))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if band != nil, !test.readings.isEmpty {
                    Text("The band is where glucose would end if your ISF were \(state.stepPercent)% either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        /// The hours the chart covers, from the bolus (from Start if none came), and why it ended early.
        private func window(for test: ISFTestState) -> String {
            let start = (test.bolusAt ?? test.startedAt).formatted(date: .omitted, time: .shortened)
            let end = (test.endedAt ?? test.plannedEnd ?? test.doseDeadline).formatted(date: .omitted, time: .shortened)
            let reason: String
            switch test.endReason {
            case .low: reason = String(localized: ". Ended early: Trio suspended insulin for a low.")
            case .endedEarly: reason = String(localized: ". You ended it early.")
            case .interrupted: reason = String(localized: ". Ended early: it was interrupted.")
            case .completed,
                 nil,
                 .noBolus,
                 .unchecked: reason = ""
            }
            return "\(start) – \(end)\(reason)"
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
            /// The insulin on board at the bolus the test counted, signed. Nil when it counted none.
            let onBoard: Decimal?
            /// The insulin Trio reported still on board at the end of the 4 hours, signed, which hadn't acted.
            let left: Decimal
            /// The units judged by: the bolus, with the insulin on board counted, less what was left at the end.
            let units: Decimal
            /// mg/dL per unit
            let isf: Decimal
            /// mg/dL per unit
            let dropPerUnit: Decimal
            /// Of the ISF
            let share: Decimal
        }

        /// Nil when the result isn't judged on the drop per unit (a low, or no verdict), or when working it out again
        /// doesn't give the verdict the headline shows.
        private func working(for test: ISFTestState) -> Working? {
            guard let evaluation = state.evaluation,
                  let dropPerUnit = evaluation.dropPerUnit,
                  let share = evaluation.share,
                  let start = test.startGlucose,
                  let end = test.endGlucose,
                  let bolus = test.bolusUnits,
                  let left = test.iobAtEnd,
                  let units = ISFTestEvaluator.judgedUnits(of: test)
            else { return nil }
            return Working(
                start: start,
                end: end,
                bolus: bolus,
                onBoard: test.iobHandling == .count ? test.iobAtBolus : nil,
                left: left,
                units: units,
                isf: test.isf,
                dropPerUnit: dropPerUnit,
                share: share
            )
        }

        /// First Bolus − Left = Units: the insulin Trio reported still on board at the end of the 4 hours hadn't acted, so
        /// it is left out. In a test that counted insulin on board, Bolus + On board − Left = Units (Bolus − Held back −
        /// Left for negative insulin on board). On a line of its own, so the next fits a small phone. Then (Start − End) ÷
        /// Units = per unit, then (Per unit − ISF) ÷ ISF = how far off it is, with the ISF in blue because it is the
        /// user's setting, and under it the docs' smallest change, which is what decides the result. Insulin on board is
        /// measured, so it is neutral.
        private func formulaCard(for working: Working) -> some View {
            let units = state.glucoseUnits.rawValue
            let start = SettingsTestFormulaTerm(
                label: String(localized: "Start"),
                value: state.format(working.start),
                unit: units,
                fromSettings: false
            )
            let end = SettingsTestFormulaTerm(
                label: String(localized: "End"),
                value: state.format(working.end),
                unit: units,
                fromSettings: false
            )
            // Each amount is shown to 2 decimals, so the units follow "≈" when any of them had more.
            let amounts = [working.bolus, working.left, working.units] + (working.onBoard.map { [$0] } ?? [])
            let given = SettingsTestFormulaTerm(
                label: String(localized: "Units"),
                value: state.formatUnits(working.units),
                unit: "U",
                fromSettings: false,
                approximate: amounts.contains { rounded($0, scale: 2, roundingMode: .plain) != $0 }
            )
            var rows: [[SettingsTestFormulaPart]] = []
            var results: [SettingsTestFormulaTerm] = []
            let bolus = SettingsTestFormulaTerm(
                label: String(localized: "Bolus"),
                value: state.formatUnits(working.bolus),
                unit: "U",
                fromSettings: false
            )
            var unitsRow: [SettingsTestFormulaPart] = [.term(bolus)]
            if let onBoard = working.onBoard {
                let board = SettingsTestFormulaTerm(
                    label: onBoard < 0 ? String(localized: "Held back") : String(localized: "On board"),
                    value: state.formatUnits(abs(onBoard)),
                    unit: "U",
                    fromSettings: false
                )
                unitsRow += [.op(onBoard < 0 ? "−" : "+"), .term(board)]
            }
            // "Left", short, so the row fits a small phone: on board at the end of the 4 hours.
            let left = SettingsTestFormulaTerm(
                label: String(localized: "Left"),
                value: state.formatUnits(abs(working.left)),
                unit: "U",
                fromSettings: false
            )
            unitsRow += [.op(working.left < 0 ? "+" : "−"), .term(left)]
            rows.append(unitsRow)
            results.append(given)
            // Both results are rounded for display (the share toward zero, so it never reads as the docs' step before it
            // has reached it), so each follows "≈": worked out from the shown numbers they can be a percent apart. The
            // verdict uses the exact share.
            let perUnit = SettingsTestFormulaTerm(
                label: String(localized: "Per unit"),
                value: state.formatPerUnit(working.dropPerUnit),
                unit: "\(units)/U",
                fromSettings: false,
                approximate: true
            )
            let isf = SettingsTestFormulaTerm(
                label: String(localized: "ISF"),
                value: state.formatISF(working.isf),
                unit: "\(units)/U",
                fromSettings: true
            )
            // Short, so the label above the result doesn't shrink to fit its column.
            let difference = SettingsTestFormulaTerm(
                label: String(localized: "Off by"),
                value: state.formatPercent(working.share),
                unit: String(localized: "of ISF"),
                fromSettings: false,
                approximate: true
            )

            rows.append([.op("("), .term(start), .op("−"), .term(end), .op(")"), .op("÷"), .term(given)])
            results.append(perUnit)
            rows.append([.op("("), .term(perUnit), .op("−"), .term(isf), .op(")"), .op("÷"), .term(isf)])
            results.append(difference)
            return SettingsTestFormulaCard(
                title: String(localized: "How Trio worked this out"),
                rows: rows,
                result: results,
                conclusion: Text("The docs' smallest change is \(state.stepPercent)%.")
            )
        }

        // MARK: - Tablets

        /// "3 tablets (12 g) before the dose", or only the grams when they aren't a whole number of the brand saved.
        private func tabletsCard(_ tablets: ISFTestTablets) -> some View {
            let grams = state.formatGrams(tablets.grams)
            let text: String
            switch tablets.count {
            case 1: text = String(localized: "1 tablet (\(grams) g) before the dose")
            case let .some(count): text = String(localized: "\(count) tablets (\(grams) g) before the dose")
            case nil: text = String(localized: "\(grams) g of glucose tablets before the dose")
            }
            return SettingsTestCard {
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // MARK: - Next

        /// What the docs say about changing the ISF, for a result that says something, and the pages behind the result.
        private func nextCard(for outcome: ISFTestOutcome, test: ISFTestState) -> some View {
            SettingsTestCard {
                switch outcome {
                case .tooHigh,
                     .tooLow:
                    SettingsTestDocsQuote(text: "\(Docs.smallChanges)\n\(Docs.waitBetweenChanges)")
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

        /// The ISF schedule entries the hours from the bolus to the end covered, as saved at Start, e.g.
        /// "12:00 AM–6:00 AM".
        private func coveredSpans(for test: ISFTestState) -> String? {
            guard let bolusAt = test.bolusAt, let end = test.endedAt,
                  let entries = ISFTestEvaluator.coveredEntries(test.coveredEntries ?? [], from: bolusAt, to: end)
            else { return nil }
            return entries.map { SettingsTestSchedule.spanText(of: $0, inSentence: true) }.formatted(.list(type: .and))
        }
    }
}
