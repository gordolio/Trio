import SwiftUI

extension CarbRatioTest {
    /// Before Begin, one question per page (`CheckPage`), each about a screen long: the checks; the tablets with their
    /// dose; how long to watch; how to handle insulin on board, only when it is over the test's line; and a summary with
    /// Begin. The step bar shows Check on every page. Next and Begin are off while a check blocks, with its sentence.
    struct CheckView: View {
        @Bindable var state: StateModel

        var body: some View {
            let page = state.shownCheckPage
            Group {
                switch page {
                case .checks: ChecksPage(state: state)
                case .tablets: TabletsPage(state: state)
                case .length: LengthPage(state: state)
                case .iob: IOBPage(state: state)
                case .ready: ReadyPage(state: state)
                }
            }
            // On screen now, so Begin knows its question was asked. Inside the page's identity, so each page tells it.
            .onAppear { state.checkPageAppeared(page) }
            // A page of its own, scrolled to its top.
            .id(page)
        }
    }

    /// Next, under every page but the last, and Back, under every page but the first.
    private struct NextFooter: View {
        let state: StateModel
        var showsBack = true

        var body: some View {
            SettingsTestPageFooter(
                blocker: state.startBlocker,
                back: showsBack ? { state.previousCheckPage() } : nil
            ) {
                Button("Next") { state.nextCheckPage() }
                    .buttonStyle(.testPrimary)
                    .disabled(!state.canGoOn)
            }
        }
    }

    // MARK: - 1. Checks

    /// The app facts that must hold, folded into one line once they pass, then the readings that only inform, one line
    /// each, with their details one tap away.
    private struct ChecksPage: View {
        let state: StateModel

        /// Whether the passed checks are shown one by one.
        @State private var showsPassedChecks = false

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestHeader(
                    icon: SettingsTestKind.carbRatio.icon,
                    title: String(localized: "Check Your Carb Ratio"),
                    subtitle: String(
                        localized: "You take glucose tablets with a bolus for their carbs, then watch for 3 or 4 hours. The test checks where glucose ends against where it started, for your carb ratio."
                    )
                )

                SettingsTestStepsButton(
                    title: String(localized: "How the carb ratio test goes"),
                    items: CheckView.steps()
                )

                SettingsTestCard(title: String(localized: "Ready to start?")) {
                    // A check that fails stays in view on its own; the ones that pass fold into one line.
                    ForEach(state.failingChecks) { check in
                        SettingsTestCheckRow(title: check.title, detail: check.detail, state: check.state, info: check.info)
                    }
                    if !state.passingChecks.isEmpty {
                        passedChecksRow
                        if showsPassedChecks {
                            ForEach(state.passingChecks) { check in
                                SettingsTestCheckRow(
                                    title: check.title,
                                    detail: check.detail,
                                    state: check.state,
                                    info: check.info
                                )
                            }
                        }
                    }
                }

                SettingsTestCard(title: String(localized: "Good to know (doesn't block the start)")) {
                    ForEach(state.informingChecks) { check in
                        informingRow(for: check)
                    }
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                NextFooter(state: state, showsBack: false)
            }
        }

        /// The reading on one line, and under it the short line the user needs before Begin, if the row has one.
        private func informingRow(for check: StateModel.Check) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                SettingsTestValueRow(title: check.title, value: check.value ?? "", info: check.info, state: check.state)
                if let detail = check.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var passedChecksRow: some View {
            let summary = SettingsTestFormat.passedChecksSummary(
                passing: state.passingChecks.count,
                total: state.blockingChecks.count
            )
            let icon = Image(systemName: SettingsTestCheckState.passed.icon)
                .font(.title3)
                .foregroundStyle(SettingsTestCheckState.passed.color)
            let text = Text(summary)
                .font(.subheadline.weight(.semibold))
            let chevron = Image(systemName: showsPassedChecks ? "chevron.up" : "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            return Button {
                withAnimation { showsPassedChecks.toggle() }
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        // The tick and the chevron on a line above the summary, so it has the card's width: between them,
                        // "checks" broke mid-word at AX5 Bold on a small phone.
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                icon
                                Spacer(minLength: 0)
                                chevron
                            }
                            text
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            icon
                            text
                            Spacer(minLength: 0)
                            chevron
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(showsPassedChecks ? "Hides the checks" : "Shows the checks"))
        }
    }

    // MARK: - 2. Tablets

    /// The brand and how many, the docs' line on counted carbs above them, and the bolus for them, carbs ÷ CR, with the
    /// carb ratio in blue and how clearly these tablets can show a docs step of it.
    private struct TabletsPage: View {
        @Bindable var state: StateModel

        /// The stepper sets the count picked; it shows the count kept within the limits.
        private var countBinding: Binding<Int> {
            Binding(
                get: { state.tabletCount ?? 1 },
                set: { state.wantedTabletCount = $0 }
            )
        }

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "Your glucose tablets"),
                    position: state.checkPagePosition(.tablets)
                )

                // The brand and the count in one card, so the page fits a screen.
                SettingsTestCard {
                    SettingsTestDocsQuote(text: Docs.countedCarbs)
                    SettingsTestTabletBrandPicker(selection: $state.selectedBrand)
                    Divider()
                    if let count = state.tabletCount {
                        Stepper(value: countBinding, in: 1 ... max(1, state.maxTablets)) {
                            let grams = SettingsTestFormat.keepTogether(state.formatGrams(state.tabletCarbs), unit: "g")
                            Text(
                                count == 1 ? String(localized: "1 tablet · \(grams)") :
                                    String(localized: "\(count) tablets · \(grams)")
                            )
                            .font(.headline)
                        }
                        if state.maxTablets < Config.maxTabletCount, let limits = state.limitsReading {
                            Text("Up to \(state.maxTablets) within your limits (\(limits)).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let blocker = state.failingChecks.first(where: { $0.id == "tablets" })?.detail {
                        Text(blocker)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let ratio = state.settingsNow.carbRatio, let dose = state.checkDose {
                    formulaCard(ratio: ratio, dose: dose)
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                NextFooter(state: state)
            }
        }

        /// Carbs ÷ CR = Dose, laid out like the Bolus Calculator Details sheet, with the carb ratio in blue because it is
        /// the user's own setting, and under it how far a docs step of the carb ratio moves where glucose ends.
        private func formulaCard(ratio: Decimal, dose: Decimal) -> some View {
            let carbs = SettingsTestFormulaTerm(
                label: String(localized: "Carbs"),
                value: state.formatGrams(state.tabletCarbs),
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
                approximate: state.checkDoseIsApproximate
            )
            return SettingsTestFormulaCard(
                title: String(localized: "The bolus for the tablets"),
                rows: [[.term(carbs), .op("÷"), .term(ratioTerm)]],
                result: [doseTerm],
                conclusion: state.precisionLine.map { Text($0) }
            )
        }
    }

    // MARK: - 3. How long

    /// The docs' 3 to 4 hours, the longer one picked first.
    private struct LengthPage: View {
        @Bindable var state: StateModel

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "How long to watch"),
                    position: state.checkPagePosition(.length)
                )

                SettingsTestCard {
                    SettingsTestDocsQuote(text: "\(Docs.monitor)\n\(Docs.avoidFood)")
                    Picker("How long to watch", selection: $state.selectedLength) {
                        ForEach(Config.lengths, id: \.self) { length in
                            Text(state.lengthText(length)).tag(length)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("The test ends this long after your bolus.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                NextFooter(state: state)
            }
        }
    }

    // MARK: - 4. Insulin on board

    /// Only when insulin on board is over the test's line: why it matters, with the line in blue because it comes from
    /// the user's settings, and the two ways to handle it, Wait for It first and picked.
    private struct IOBPage: View {
        @Bindable var state: StateModel

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "Insulin on board"),
                    position: state.checkPagePosition(.iob)
                )

                if case let .choice(line) = state.iobDecision, let dose = state.checkDose {
                    choiceCard(line: line, dose: dose)
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                NextFooter(state: state)
            }
        }

        private func choiceCard(line: Decimal, dose: Decimal) -> some View {
            let lineText = Text(verbatim: state.lineText(line)).foregroundStyle(Color.accentColor)
            // The page shows only for a choice, which needs insulin on board read.
            let current = state.currentIOB ?? 0
            let iob = SettingsTestFormat.keepTogether(state.formatSignedUnits(current), unit: "U")
            let doseText = SettingsTestFormat.keepTogether(state.formatUnits(dose), unit: "U")
            let held = current < 0
            let explanation = held
                ? Text(
                    "Your insulin on board is \(iob): Trio held back basal recently. The test's dose is \(doseText), and more than \(lineText) either way (what a \(state.stepText) change of your carb ratio, the smallest change in Trio docs, makes in it) can sway the result."
                )
                : Text(
                    "\(iob) is still working from an earlier dose or SMB. The test's dose is \(doseText), and more than \(lineText) on board (what a \(state.stepText) change of your carb ratio, the smallest change in Trio docs, makes in it) can sway the result."
                )
            let waitDetail = held
                ? Text(
                    "SMBs stop when you begin. Your dose unlocks once it's within \(lineText) of zero, up to \(state.settleAllowanceText)."
                )
                :
                Text(
                    "SMBs stop when you begin. Your dose unlocks once it's under \(lineText), up to \(state.settleAllowanceText)."
                )
            return SettingsTestCard {
                explanation
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("How should the test handle it?")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                IOBOption(
                    title: Text("Wait for It"),
                    detail: waitDetail,
                    isSelected: state.iobChoice == .wait
                ) { state.iobChoice = .wait }
                IOBOption(
                    title: Text("Count It"),
                    detail: Text("Begin now. Your dose takes off what's on board, and the result counts it with your bolus."),
                    isSelected: state.iobChoice == .count
                ) { state.iobChoice = .count }
            }
        }
    }

    // MARK: - 5. Ready

    /// What was picked, the rules while Basal Testing is on, and Begin.
    private struct ReadyPage: View {
        @Bindable var state: StateModel

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "Ready to begin"),
                    position: state.checkPagePosition(.ready)
                )

                SettingsTestCard {
                    ForEach(state.readySummary, id: \.title) { row in
                        SettingsTestValueRow(title: row.title, value: row.value)
                    }
                }

                SettingsTestCard(title: String(localized: "While Basal Testing is on")) {
                    bullet(Text("Trio won't correct highs, give SMBs, or adjust for sensitivity."))
                    bullet(Text("If Trio suspends insulin for a low, the test ends: treat the low as usual."))
                    bullet(Text("Your usual dosing mode returns when the test ends."))
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                SettingsTestPageFooter(blocker: state.startBlocker, back: { state.previousCheckPage() }) {
                    Button("Begin Test") { state.requestStart() }
                        .buttonStyle(.testPrimary)
                        .disabled(!state.readyToStart)
                        // On the button it confirms, as the other steps' dialogs are.
                        .alert("Begin the carb ratio test?", isPresented: $state.showStartConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Begin") { state.confirmStart() }
                        } message: {
                            Text(
                                "Trio switches to Basal Testing now, so SMBs stop, and the test starts after a short settling step. Trio returns to \(state.currentMode.displayName) when the test ends."
                            )
                        }
                }
            }
        }

        /// The dot is text in the row's own font, so it sits on the first line at every text size.
        private func bullet(_ text: Text) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                text
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
        }
    }

    /// One way to handle insulin on board: a selectable row with its title and what it does, picked with a filled circle
    /// and an accent outline, as the ISF test's are.
    private struct IOBOption: View {
        let title: Text
        let detail: Text
        let isSelected: Bool
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        title
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        detail
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }
}
