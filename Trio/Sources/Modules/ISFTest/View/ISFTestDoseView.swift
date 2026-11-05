import SwiftUI

extension ISFTest {
    /// The docs' correction dose with the user's target and ISF in blue, what Trio's own suggestion will be, and the
    /// way to Trio's Treatments screen, which gives the bolus with all its checks. The test moves on when Trio sees it.
    struct DoseView: View {
        @Bindable var state: StateModel

        @State private var showsCancelConfirmation = false

        var body: some View {
            // The dose and its gate read the time (the newest reading's age, the 4 hours from now), so the step is drawn
            // again each minute, as Settle and Wait are, and a dose from a reading grown old doesn't stay on screen.
            TimelineView(.everyMinute) { _ in
                content
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await state.checkRunningTest() }
            }
        }

        private var content: some View {
            SettingsTestScreen(paintsBackground: false) {
                if state.docsDose != nil, !state.glucoseIsLevel || state.doseWaitsForTablets {
                    // The dose waits for a flat CGM arrow on this path too (round 13), so none is shown while glucose moves,
                    // and after tablets until glucose has stopped rising again.
                    LevelingCard(
                        state: state,
                        title: ISFTestEvaluator.levelingTitle(phase: .dosing, tabletsActed: false),
                        status: state.glucoseIsLevel
                            ? nil
                            : String(localized: "Open Treatments turns on once the arrow is flat.")
                    )
                    deadlineText
                } else if let dose = state.docsDose, !state.doseIOBAllows {
                    iobWaitCard(dose: dose)
                    deadlineText
                } else if let settings = state.doseSettings, let dose = state.docsDose, let glucose = state.doseGlucose {
                    formulaCard(glucose: glucose, target: settings.target, isf: settings.isf, dose: dose)

                    SettingsTestCard {
                        SettingsTestDocsQuote(text: Docs.correctionBolus)
                    }

                    // Counted, the dose follows the docs' bolus calculator, which takes insulin on board off.
                    if state.dosesCountIOB {
                        SettingsTestCard {
                            SettingsTestDocsQuote(text: Docs.bolusCalculatorFormula)
                            Group {
                                Text("The test has no carbs and leaves trend out.")
                                if (state.doseIOB ?? 0) < 0 {
                                    Text(
                                        "The basal Trio held back is added, so the insulin working during the test is still the formula's correction."
                                    )
                                } else {
                                    Text(
                                        "Your insulin on board is taken off, so the insulin working during the test is still the formula's correction."
                                    )
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            SettingsTestDocsLinks(links: [Docs.bolusCalculatorLink])
                        }
                    }

                    if let suggestion = state.trioSuggestion {
                        SuggestionNote(state: state, suggestion: suggestion, dose: dose)
                    }

                    deadlineText
                } else {
                    noDoseCard
                    // Not on a dead end that only offers Cancel Test: there is no bolus to give.
                    if ISFTestEvaluator.showsDoseDeadline(noDose: state.noDoseReason, canRaise: state.canRaise) {
                        deadlineText
                    }
                }
            } footer: {
                if state.docsDose != nil {
                    Button("Open Treatments") { state.openTreatments() }
                        .buttonStyle(.testPrimary)
                        .disabled(!state.canDose || state.isEnding)
                    if state.canDose, !state.isEnding {
                        Text("Waiting for your bolus. The test starts when Trio sees it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if state.noDoseReason?.isWaiting == true {
                    // Waiting for a reading: the way to the dose is there, turned off until it comes.
                    Button("Open Treatments") {}
                        .buttonStyle(.testPrimary)
                        .disabled(true)
                } else if state.noDoseReason == .atOrBelowTarget, state.canRaise {
                    Button("Take Glucose Tablets") { state.raiseFirst() }
                        .buttonStyle(.testPrimary)
                        .disabled(state.isEnding)
                }
                Button("Cancel Test") { showsCancelConfirmation = true }
                    .buttonStyle(.testSecondary)
                    // Off while the test ends.
                    .disabled(state.isEnding)
                    // On the button, so where the dialog shows as a popover it points at the button.
                    .confirmationDialog("Cancel the test?", isPresented: $showsCancelConfirmation, titleVisibility: .visible) {
                        Button("Cancel Test", role: .destructive) { state.discard() }
                        Button("Keep Going", role: .cancel) {}
                    } message: {
                        Text("Your usual dosing mode comes back, and nothing is saved.")
                    }
            }
        }

        // MARK: - Dose

        /// (Current − Target) ÷ ISF = dose, laid out like the Bolus Calculator Details sheet, with the target and ISF in
        /// blue because they are the user's own settings. In a test that counts insulin on board, what is needed is worked
        /// out first and insulin on board is taken off it on a second line, "Needed − On board = Dose" ("Needed + Held
        /// back" for basal Trio held back), so neither line is too wide for a small phone. Insulin on board is measured,
        /// so it is neutral.
        private func formulaCard(glucose: Int, target: Decimal, isf: Decimal, dose: Decimal) -> some View {
            let units = state.glucoseUnits.rawValue
            let current = SettingsTestFormulaTerm(
                label: String(localized: "Current"),
                value: state.format(glucose),
                unit: units,
                fromSettings: false
            )
            let targetTerm = SettingsTestFormulaTerm(
                label: String(localized: "Target"),
                value: state.formatTarget(target),
                unit: units,
                fromSettings: true
            )
            let isfTerm = SettingsTestFormulaTerm(
                label: String(localized: "ISF"),
                value: state.formatISF(isf),
                unit: "\(units)/U",
                fromSettings: true
            )
            let doseTerm = SettingsTestFormulaTerm(
                label: String(localized: "Dose"),
                value: state.formatUnits(dose),
                unit: "U",
                fromSettings: false,
                approximate: state.docsDoseIsApproximate
            )
            let correctionRow: [SettingsTestFormulaPart] = [
                .op("("), .term(current), .op("−"), .term(targetTerm), .op(")"), .op("÷"), .term(isfTerm)
            ]
            guard state.dosesCountIOB, let correction = state.docsCorrection, let iob = state.doseIOB else {
                return SettingsTestFormulaCard(
                    title: String(localized: "Correction dose"),
                    rows: [correctionRow],
                    result: [doseTerm]
                )
            }
            // "Needed", short, so the label above the result doesn't shrink to fit its column.
            let correctionTerm = SettingsTestFormulaTerm(
                label: String(localized: "Needed"),
                value: state.formatUnits(correction),
                unit: "U",
                fromSettings: false,
                approximate: state.docsCorrectionIsApproximate
            )
            let shownIOB = rounded(iob, scale: 2, roundingMode: .plain)
            let onBoard = SettingsTestFormulaTerm(
                label: shownIOB < 0 ? String(localized: "Held back") : String(localized: "On board"),
                value: state.formatUnits(abs(shownIOB)),
                unit: "U",
                fromSettings: false
            )
            return SettingsTestFormulaCard(
                title: String(localized: "Correction dose"),
                rows: [correctionRow, [.term(correctionTerm), .op(shownIOB < 0 ? "+" : "−"), .term(onBoard)]],
                result: [correctionTerm, doseTerm]
            )
        }

        @ViewBuilder private var deadlineText: some View {
            if let deadline = state.doseDeadlineText {
                Text(deadline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }

        // MARK: - Insulin on board

        /// Glucose has leveled off, but insulin on board is over the line for this dose: the docs' smallest ISF change of
        /// the dose shown, which can be smaller than the one Begin expected. Open Treatments waits until it is under it.
        private func iobWaitCard(dose _: Decimal) -> some View {
            SettingsTestCard(title: String(localized: "Waiting for insulin on board")) {
                Text(state.iobWaitText ?? "")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Open Treatments turns on once it's under the line.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsTestDocsQuote(text: Docs.smallChanges)
            }
        }

        // MARK: - No dose

        /// Why there is no dose now (R7): carbs on board, which the docs test ISF without, no recent reading to work it out
        /// from, glucose at or below the target, no target or ISF, or, with Count It, insulin on board that covers the
        /// correction (leaving less than the pump's bolus increment) or that Trio hasn't read in the last 12 minutes.
        private var noDoseCard: some View {
            SettingsTestCard {
                switch state.noDoseReason {
                case .carbsOnBoard:
                    // The runner ends the test with the same sentence (`ISFTestEvaluator.doseDeadEnd`).
                    noDoseText(.carbsOnBoard)
                    SettingsTestDocsQuote(text: Docs.testISFWhenFasting)
                case .carbsUnread:
                    WaitingRow(text: String(localized: "Waiting for Trio to read carbs on board"))
                case .noRecentReading:
                    WaitingRow.recentReading
                case .atOrBelowTarget:
                    noDoseText(.atOrBelowTarget)
                    readingsLine
                    if !state.canRaise {
                        Text(state.tabletAimText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .iobCoversDose:
                    noDoseText(.iobCoversDose)
                case .iobUnread:
                    WaitingRow(text: String(localized: "Waiting for Trio's insulin on board"))
                case .isfChanges,
                     .isfChangesUntilDeadline:
                    // The Check screen's ISF-change row: its sentence, the hours with their ISFs, and the docs' rule.
                    noDoseText(.isfChanges)
                    if let spans = state.doseISFChangeReading {
                        Text("These hours cover \(spans)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsTestDocsQuote(text: Docs.testSystematically)
                case nil,
                     .noSettings:
                    noDoseText(.noSettings)
                }
            }
        }

        /// The card's sentence for why there is no dose (`ISFTestEvaluator.noDoseSentence`).
        @ViewBuilder private func noDoseText(_ noDose: ISFTestNoDose) -> some View {
            if let sentence = ISFTestEvaluator.noDoseSentence(noDose) {
                Text(sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        /// "Now 98 mg/dL · Target 100 mg/dL", with the target in blue because it is the user's setting.
        @ViewBuilder private var readingsLine: some View {
            if let settings = state.doseSettings, let glucose = state.doseGlucose {
                let units = state.glucoseUnits.rawValue
                let now = SettingsTestFormat.keepTogether(state.format(glucose), unit: units)
                let target = SettingsTestFormat.keepTogether(state.formatTarget(settings.target), unit: units)
                Text("Now \(now) · Target \(Text(verbatim: target).foregroundStyle(Color.accentColor))")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The yellow note: Trio's own suggestion beside the docs' dose. Yellow, not red: nothing is wrong, and either
    /// amount tests the ISF because the result is worked out per unit given, unless the suggestion is too small to judge.
    /// The tint stays light behind primary text, so it reads in light and dark mode. Its info button explains the
    /// Recommended Bolus Percentage. What it says depends on whether that percentage makes Trio's suggestion less than,
    /// the same as, or more than the docs' dose (`StateModel.suggestionNote`).
    private struct SuggestionNote: View {
        let state: StateModel
        let suggestion: Decimal
        let dose: Decimal

        @State private var isShowingInfo = false

        /// What the note and its info sheet say (`StateModel.suggestionNote`).
        private var texts: (note: String, info: String) {
            state.suggestionNote(suggestion: suggestion, dose: dose)
        }

        var body: some View {
            Button {
                isShowingInfo = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "lightbulb")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    Text(texts.note)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(Color.blue)
                        .accessibilityHidden(true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.yellow.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows more information"))
            .sheet(isPresented: $isShowingInfo) {
                SettingsTestInfoSheet(info: info)
            }
        }

        private var info: SettingsTestInfo {
            SettingsTestInfo(
                title: String(localized: "Trio's suggested bolus"),
                body: texts.info,
                links: [Docs.recommendedBolusPercentageLink]
            )
        }
    }
}
