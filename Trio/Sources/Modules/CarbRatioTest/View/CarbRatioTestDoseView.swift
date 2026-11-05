import SwiftUI

extension CarbRatioTest {
    /// The tablets and the docs' bolus for them, carbs ÷ CR with the carb ratio in blue, what Trio's own suggestion will
    /// be, and the way to Trio's Treatments screen, with the tablets' carbs filled in, which gives the bolus with all its
    /// checks. The test moves on when Trio sees the bolus.
    struct DoseView: View {
        @Bindable var state: StateModel

        @State private var showsCancelConfirmation = false

        var body: some View {
            // The dose and its gate read the time (the newest reading's age), so the step is drawn again each minute, as
            // Settle and Wait are, and a dose from a reading grown old doesn't stay on screen.
            TimelineView(.everyMinute) { _ in
                content
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await state.checkRunningTest() }
            }
        }

        private var content: some View {
            SettingsTestScreen(paintsBackground: false) {
                // The tablets' carbs came first: the bolus is all that's left, against the meal's clock.
                if let test = state.test, test.carbsLoggedAwaitingBolus {
                    carbsLoggedCard(test: test)
                }
                switch state.noDoseReason {
                case nil:
                    if let test = state.test, let settings = state.doseSettings, let dose = state.docsDose {
                        if !test.carbsLoggedAwaitingBolus {
                            stepsCard(test: test, dose: dose)
                        }
                        formulaCard(carbs: test.tabletCarbs, ratio: settings.carbRatio, dose: dose)

                        SettingsTestCard {
                            SettingsTestDocsQuote(text: "\(Docs.calculateInsulin)\n\(Docs.fullBolus)")
                        }

                        // Counted, the dose follows the docs' bolus calculator, which takes insulin on board off.
                        if state.dosesCountIOB {
                            countedCard
                        }

                        if let suggestion = state.trioSuggestion {
                            SuggestionNote(state: state, suggestion: suggestion, dose: dose)
                        }
                    }
                    deadlineText
                case .notLevel:
                    // The dose waits for a flat CGM arrow, so none is shown while glucose moves.
                    LevelingCard(state: state)
                    deadlineText
                case .iobOverLine:
                    iobWaitCard
                    deadlineText
                case .carbsUnread,
                     .iobUnread,
                     .noRecentReading:
                    SettingsTestCard {
                        ISFTest.WaitingRow(text: state.noDoseReason?.sentence ?? "")
                    }
                    deadlineText
                case .carbsOnBoard:
                    SettingsTestCard {
                        noDoseText(.carbsOnBoard)
                        SettingsTestDocsQuote(text: Docs.minimalCOB)
                    }
                    deadlineText
                case .iobCoversDose:
                    // A wait: the counted dose comes back as insulin on board wears off, and the dose deadline ends it.
                    SettingsTestCard {
                        noDoseText(.iobCoversDose)
                        Text("Open Treatments turns on once enough of it has worn off to leave a dose.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    deadlineText
                case .noSettings:
                    // A dead end that offers only Cancel Test: there is no bolus to give.
                    SettingsTestCard {
                        noDoseText(.noSettings)
                    }
                }
            } footer: {
                if state.docsDose != nil || state.noDoseReason?.isWaiting == true {
                    Button("Open Treatments") { state.openTreatments() }
                        .buttonStyle(.testPrimary)
                        .disabled(!state.canDose || state.isEnding)
                    if state.canDose, !state.isEnding {
                        Text("Waiting for your bolus. The test goes on when Trio sees it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

        // MARK: - The steps

        /// What to do, in order: Treatments with the carbs filled in, the bolus with them, then the tablets.
        private func stepsCard(test: CarbRatioTestState, dose: Decimal) -> some View {
            let carbs = SettingsTestFormat.keepTogether(state.formatGrams(test.tabletCarbs), unit: "g")
            let units = SettingsTestFormat.keepTogether(state.formatUnits(dose), unit: "U")
            let brand = test.brand?.displayName ?? test.tabletBrand
            let tablets = test.tabletCount == 1
                ? String(localized: "1 \(brand) tablet")
                : String(localized: "\(test.tabletCount) \(brand) tablets")
            return SettingsTestCard(title: String(localized: "Give the bolus, then take the tablets")) {
                numbered(1, Text("Open Treatments. The tablets' \(carbs) are filled in: check them."))
                numbered(2, Text("Give the bolus, \(Text(verbatim: units).bold()), with the carbs."))
                numbered(3, Text("Then take the \(tablets)."))
                Text("The test reads the carbs you log with the bolus. Log no other food until it ends.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        /// The tablets' carbs are logged and the bolus hasn't come: the bolus now, with the minutes left of the meal's 15,
        /// then the tablets. Treatments opens with nothing filled in, since the carbs are in.
        private func carbsLoggedCard(test: CarbRatioTestState) -> some View {
            let dose = state.docsDose ?? state.formulaDose
            let minutes = test.minutesLeftForBolus(at: Date()) ?? 0
            let pairing = Int(Config.mealPairing / 60)
            let time = test.bolusDeadline?.formatted(date: .omitted, time: .shortened) ?? ""
            return SettingsTestCard {
                Label {
                    if let dose {
                        let units = SettingsTestFormat.keepTogether(state.formatUnits(dose), unit: "U")
                        Text("The tablets' carbs are logged. Give the bolus now: \(Text(verbatim: units).bold()).")
                    } else {
                        Text("The tablets' carbs are logged. Give the bolus now.")
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "\(minutes) of \(pairing) minutes left, until \(time). Enter only the bolus in Treatments: the carbs are in. Then take the tablets."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func numbered(_ number: Int, _ text: Text) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                text
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }

        // MARK: - Dose

        /// Carbs ÷ CR = Dose, laid out like the Bolus Calculator Details sheet, with the carb ratio in blue because it is
        /// the user's own setting. In a test that counts insulin on board, what is needed is worked out first and insulin
        /// on board is taken off it on a second line, "Needed − On board = Dose" ("Needed + Held back" for basal Trio held
        /// back). Insulin on board is measured, so it is neutral.
        private func formulaCard(carbs: Decimal, ratio: Decimal, dose: Decimal) -> some View {
            let carbsTerm = SettingsTestFormulaTerm(
                label: String(localized: "Carbs"),
                value: state.formatGrams(carbs),
                unit: "g",
                fromSettings: false
            )
            let ratioTerm = SettingsTestFormulaTerm(
                label: String(localized: "CR"),
                value: state.formatCarbRatio(ratio),
                unit: "g/U",
                fromSettings: true
            )
            let doseTerm = SettingsTestFormulaTerm(
                label: String(localized: "Dose"),
                value: state.formatUnits(dose),
                unit: "U",
                fromSettings: false,
                approximate: state.docsDoseIsApproximate
            )
            let formulaRow: [SettingsTestFormulaPart] = [.term(carbsTerm), .op("÷"), .term(ratioTerm)]
            guard state.dosesCountIOB, let formula = state.formulaDose, let iob = state.doseIOB else {
                return SettingsTestFormulaCard(
                    title: String(localized: "The bolus for the tablets"),
                    rows: [formulaRow],
                    result: [doseTerm]
                )
            }
            let needed = SettingsTestFormulaTerm(
                label: String(localized: "Needed"),
                value: state.formatUnits(formula),
                unit: "U",
                fromSettings: false,
                approximate: state.formulaDoseIsApproximate
            )
            let shownIOB = rounded(iob, scale: 2, roundingMode: .plain)
            let onBoard = SettingsTestFormulaTerm(
                label: shownIOB < 0 ? String(localized: "Held back") : String(localized: "On board"),
                value: state.formatUnits(abs(shownIOB)),
                unit: "U",
                fromSettings: false
            )
            return SettingsTestFormulaCard(
                title: String(localized: "The bolus for the tablets"),
                rows: [formulaRow, [.term(needed), .op(shownIOB < 0 ? "+" : "−"), .term(onBoard)]],
                result: [needed, doseTerm]
            )
        }

        /// Count It: the docs' bolus calculator takes insulin on board off, and the test leaves the correction and the
        /// trend out.
        private var countedCard: some View {
            SettingsTestCard {
                SettingsTestDocsQuote(text: Docs.bolusCalculatorFormula)
                Group {
                    Text("The test leaves the correction and the trend out.")
                    if (state.doseIOB ?? 0) < 0 {
                        Text(
                            "The basal Trio held back is added, so the insulin working during the test is still the formula's dose for the tablets."
                        )
                    } else {
                        Text(
                            "Your insulin on board is taken off, so the insulin working during the test is still the formula's dose for the tablets."
                        )
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                SettingsTestDocsLinks(links: [Docs.bolusCalculatorLink])
            }
        }

        /// The time the bolus must come by. Not once the carbs are logged, whose card says the meal's own.
        @ViewBuilder private var deadlineText: some View {
            if state.test?.carbsLoggedAwaitingBolus != true, let deadline = state.doseDeadlineText {
                Text(deadline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }

        // MARK: - Waiting

        /// Glucose has leveled off, but insulin on board is over the line for this dose. Open Treatments waits until it is
        /// under it.
        private var iobWaitCard: some View {
            SettingsTestCard(title: String(localized: "Waiting for insulin on board")) {
                Text(state.iobWaitText ?? "")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Open Treatments turns on once it's under the line.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsTestDocsQuote(text: Docs.minimalIOB)
            }
        }

        /// The card's sentence for why there is no dose (`CarbRatioTestNoDose.sentence`).
        private func noDoseText(_ noDose: CarbRatioTestNoDose) -> some View {
            Text(noDose.sentence)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Glucose leveling off before the dose: the newest reading with the CGM's arrow, what the dose waits for, and the
    /// last readings, as the ISF test's leveling card shows them.
    struct LevelingCard: View {
        let state: StateModel

        var body: some View {
            // The ISF test's title for it, without the sentence's full stop.
            SettingsTestCard(title: ISFTestEvaluator.levelingTitle(phase: .dosing, tabletsActed: true)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.currentGlucose.map(state.formatWithUnits) ?? "--")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let arrow = state.trendArrow {
                        Text(verbatim: arrow)
                            .font(.title2)
                            .accessibilityLabel(Text("Trend \(arrow)"))
                    }
                    Spacer(minLength: 0)
                }

                Text("Open Treatments turns on once the arrow is flat.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !state.recentReadings.isEmpty {
                    Divider()
                    readings(Array(state.recentReadings.prefix(4)))
                }
            }
        }

        /// Each reading's time at the leading edge and its glucose at the trailing edge, or stacked when the widest row
        /// doesn't fit that way at this text size.
        private func readings(_ readings: [BasalTestReading]) -> some View {
            ViewThatFits(in: .horizontal) {
                VStack(spacing: 12) {
                    ForEach(readings, id: \.date) { reading in
                        HStack {
                            time(of: reading)
                            Spacer()
                            glucose(of: reading)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(readings, id: \.date) { reading in
                        VStack(alignment: .leading, spacing: 2) {
                            time(of: reading)
                            glucose(of: reading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.subheadline)
        }

        private func time(of reading: BasalTestReading) -> some View {
            Text(reading.date.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }

        private func glucose(of reading: BasalTestReading) -> some View {
            Text(state.formatWithUnits(reading.glucose))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The yellow note: Trio's own suggestion beside the docs' dose, as the ISF test's. Yellow, not red: nothing is
    /// wrong, and either amount tests the carb ratio because the result is worked out from the units given. Its info
    /// button explains the Recommended Bolus Percentage, and that Trio also adds a correction and takes insulin on board
    /// off (`StateModel.suggestionNote`).
    private struct SuggestionNote: View {
        let state: StateModel
        let suggestion: Decimal
        let dose: Decimal

        @State private var isShowingInfo = false

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
