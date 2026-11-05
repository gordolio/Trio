import SwiftUI

extension ISFTest {
    /// Before Begin, one question per page (`CheckPage`), each about a screen long: the checks; how to handle insulin on
    /// board, only when it is over the test's line; and a summary with Begin. The step bar shows Check on every page.
    /// Next and Begin are off while a check blocks, with its sentence.
    struct CheckView: View {
        @Bindable var state: StateModel

        var body: some View {
            let page = state.shownCheckPage
            Group {
                switch page {
                case .checks: ChecksPage(state: state)
                case .iob: IOBPage(state: state)
                case .ready: ReadyPage(state: state)
                }
            }
            // On screen now, so Begin knows its question was asked. Inside the page's identity, so each page tells it.
            .onAppear { state.checkPageAppeared(page) }
            // A page of its own, scrolled to its top.
            .id(page)
        }

        // MARK: - Steps

        /// Every step, as each one's screen and the runner run it, for the steps sheet. `aim` is the docs' starting
        /// glucose in the user's units.
        static func steps(aim: String) -> [SettingsTestStepItem<Step>] {
            let readings = Config.settleReadings
            let doseMinutes = Int(Config.doseAllowance / 60)
            return [
                .init(
                    step: .check,
                    detail: Text(
                        "The checks, then a page for insulin on board when it's over the test's line. Next turns on once each check passes."
                    )
                ),
                .init(
                    step: .settle,
                    detail: Text(
                        "Trio switches to Basal Testing, so SMBs stop. The test waits for Trio's first loop in it and \(readings) CGM readings after that. If you chose Wait for It, it also waits, up to an hour, for insulin on board to come within the line of zero."
                    )
                ),
                .init(
                    step: .raise,
                    detail: Text(
                        "Only when glucose is under \(aim) and your target is lower than that. Glucose tablets aim for around \(aim), then glucose levels off. You can skip them and dose from where you are."
                    )
                ),
                .init(
                    step: .dose,
                    detail: Text(
                        "The step works out the correction from your target and ISF and waits for a flat CGM arrow, or a recent reading with none. You open Treatments and give that dose there, within \(doseMinutes) minutes."
                    )
                ),
                .init(
                    step: .wait,
                    detail: Text("4 hours without eating or exercising. Logged carbs or another bolus end the test.")
                ),
                .init(
                    step: .result,
                    detail: Text("How far glucose fell for each unit, against your ISF, and which way it leans.")
                )
            ]
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

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestHeader(
                    icon: "drop.fill",
                    title: String(localized: "Check Your ISF"),
                    subtitle: String(
                        localized: "You give a correction bolus and wait 4 hours. The test checks how far glucose falls for each unit, against your ISF."
                    )
                )

                SettingsTestStepsButton(
                    title: String(localized: "How the ISF test goes"),
                    items: CheckView.steps(aim: state.formatWithUnits(Config.docsStartAim))
                )

                SettingsTestCard(title: String(localized: "Ready to start?")) {
                    // A check that fails stays in view on its own; the ones that pass fold into one line.
                    ForEach(state.failingChecks) { check in
                        checkRow(for: check)
                    }
                    if !state.passingChecks.isEmpty {
                        passedChecksRow
                        if showsPassedChecks {
                            ForEach(state.passingChecks) { check in
                                checkRow(for: check)
                            }
                        }
                    }
                }

                SettingsTestCard(title: String(localized: "Good to know (doesn't block the start)")) {
                    ForEach(state.informingChecks) { check in
                        informingRow(for: check)
                    }
                }
            } footer: {
                NextFooter(state: state, showsBack: false)
            }
        }

        private func checkRow(for check: StateModel.Check) -> some View {
            SettingsTestCheckRow(title: check.title, detail: check.detail, state: check.state, info: check.info)
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
            return Button {
                withAnimation { showsPassedChecks.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: SettingsTestCheckState.passed.icon)
                        .font(.title3)
                        .foregroundStyle(SettingsTestCheckState.passed.color)
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: showsPassedChecks ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(showsPassedChecks ? "Hides the checks" : "Shows the checks"))
        }
    }

    // MARK: - 2. Insulin on board

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

                if case let .choice(line) = state.iobDecision, let dose = state.expectedDose {
                    choiceCard(line: line, dose: dose)
                }
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
                    "Your insulin on board is \(iob): Trio held back basal recently. The test's dose is about \(doseText), and more than \(lineText) either way (\(state.stepPercent)% of it, the smallest ISF change in Trio docs) can sway the result."
                )
                : Text(
                    "\(iob) is still working from an earlier dose or SMB. The test's dose is about \(doseText), and more than \(lineText) on board (\(state.stepPercent)% of it, the smallest ISF change in Trio docs) can sway the result."
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

    // MARK: - 3. Ready

    /// What the test does first, its dose and how insulin on board is handled, the rules while Basal Testing is on, and
    /// Begin.
    private struct ReadyPage: View {
        @Bindable var state: StateModel

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "Ready to begin"),
                    position: state.checkPagePosition(.ready)
                )

                if !state.readySummary.isEmpty {
                    SettingsTestCard {
                        ForEach(state.readySummary, id: \.title) { row in
                            SettingsTestValueRow(title: row.title, value: row.value)
                        }
                    }
                }

                SettingsTestCard(title: String(localized: "While Basal Testing is on")) {
                    bullet(Text("Trio won't correct highs, give SMBs, or adjust for sensitivity."))
                    bullet(Text("If Trio suspends insulin for a low, the test ends: treat the low as usual."))
                    bullet(Text("Your usual dosing mode returns when the test ends."))
                }
            } footer: {
                SettingsTestPageFooter(blocker: state.startBlocker, back: { state.previousCheckPage() }) {
                    Button("Begin Test") { state.requestStart() }
                        .buttonStyle(.testPrimary)
                        .disabled(!state.readyToStart)
                        // On the button it confirms, as the other steps' dialogs are.
                        .alert("Begin the ISF test?", isPresented: $state.showStartConfirmation) {
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
    /// and an accent outline, as the tablet brands are.
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
