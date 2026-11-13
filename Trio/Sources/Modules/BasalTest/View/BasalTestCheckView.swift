import SwiftUI

extension BasalTest {
    /// Before Start, one question per page (`CheckPage`), each about a screen long: the checks; how long to fast; and a
    /// summary with Start. The step bar shows Check on every page. Next and Start are off while a check blocks, with its
    /// sentence.
    struct CheckView: View {
        @Bindable var state: StateModel

        var body: some View {
            Group {
                switch state.shownCheckPage {
                case .checks: ChecksPage(state: state)
                case .length: LengthPage(state: state)
                case .ready: ReadyPage(state: state)
                }
            }
            // A page of its own, scrolled to its top.
            .id(state.shownCheckPage)
        }

        // MARK: - Steps

        /// Every step, for the steps sheet. The sheet opens from the checks, before the hours are picked, so the fast is
        /// the range of hours to pick from.
        static func steps() -> [SettingsTestStepItem<Step>] {
            let shortest = Config.durationChoices.min() ?? 4
            let longest = Config.durationChoices.max() ?? 6
            return [
                .init(
                    step: .check,
                    detail: Text("The checks, then a page for how long to fast. Next turns on once each check passes.")
                ),
                .init(
                    step: .fast,
                    detail: Text(
                        "\(shortest) to \(longest) hours in Basal Testing, as long as you pick. Don't eat or bolus until it ends, unless you need to treat a low."
                    )
                ),
                .init(
                    step: .result,
                    detail: Text("Whether glucose stayed steady, or which way your basal leans for the hours it covered.")
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

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestHeader(
                    icon: "waveform.path.ecg",
                    title: String(localized: "Check Your Basal"),
                    subtitle: String(
                        localized: "You fast for a few hours with Trio holding back its adjustments. If glucose stays flat, your basal rates are doing their job."
                    )
                )

                SettingsTestStepsButton(
                    title: String(localized: "How the basal test goes"),
                    items: CheckView.steps()
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
                        SettingsTestValueRow(title: check.title, value: check.value ?? check.detail ?? "", info: check.info)
                    }
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                NextFooter(state: state, showsBack: false)
            }
        }

        private func checkRow(for check: StateModel.Check) -> some View {
            SettingsTestCheckRow(title: check.title, detail: check.detail, state: check.state, info: check.info)
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

    // MARK: - 2. How long

    /// The hours picker, the hours a fast started now covers with the rates in them, the SMBs Trio gave in those hours
    /// over the past week, and the docs' line on times of day. The hours keep up with the clock while the page is open.
    private struct LengthPage: View {
        @Bindable var state: StateModel

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "How long to fast"),
                    position: state.checkPagePosition(.length)
                )

                TimelineView(.everyMinute) { context in
                    SettingsTestCard {
                        hoursPicker
                        plannedWindowText(startingAt: context.date)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        // Counted over the hours picked, so it sits with them.
                        if let smbs = state.smbCheck {
                            Divider()
                            SettingsTestValueRow(title: smbs.title, value: smbs.value ?? "", info: smbs.info)
                        }
                        SettingsTestDocsQuote(text: Docs.testTimesOfDaySeparately)
                    }
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                NextFooter(state: state)
            }
        }

        /// A segmented control doesn't grow with the text size, so at accessibility sizes it becomes a menu, as
        /// upstream's settings pickers are.
        @ViewBuilder private var hoursPicker: some View {
            let picker = Picker("Hours", selection: $state.selectedHours) {
                ForEach(Config.durationChoices, id: \.self) { hours in
                    Text("\(hours) h").tag(hours)
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }

        /// "This fast: 2:20 AM – 6:20 AM · covers 12:00 AM–6:00 AM at 0.80 U/h", with the rates in blue because they
        /// are the user's own settings.
        private func plannedWindowText(startingAt start: Date) -> Text {
            let window = state.plannedWindow(startingAt: start)
            let times =
                "\(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))"
            var text = Text("This fast: \(times)")
            for (index, entry) in window.covered.enumerated() {
                let span = SettingsTestSchedule.spanText(of: entry, inSentence: true)
                let rate = entry.value.formatted(.number.precision(.fractionLength(2)))
                text = text
                    + Text(verbatim: index == 0 ? " · " : ", ")
                    + (index == 0 ? Text("covers \(span) at ") : Text(verbatim: "\(span) at "))
                    + Text(verbatim: SettingsTestFormat.keepTogether(rate, unit: "U/h")).foregroundStyle(Color.accentColor)
            }
            return text
        }
    }

    // MARK: - 3. Ready

    /// How long the fast is and when it ends, the rules while Basal Testing is on, and Start.
    private struct ReadyPage: View {
        @Bindable var state: StateModel

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestPageHeading(
                    title: String(localized: "Ready to begin"),
                    position: state.checkPagePosition(.ready)
                )

                // The end is a clock time from now, so it keeps up while the page is open.
                TimelineView(.everyMinute) { context in
                    SettingsTestCard {
                        ForEach(state.readySummary(now: context.date), id: \.title) { row in
                            SettingsTestValueRow(title: row.title, value: row.value)
                        }
                    }
                }

                SettingsTestCard(title: String(localized: "While Basal Testing is on")) {
                    bullet(Text("Trio won't correct highs, give SMBs, or adjust for sensitivity."))
                    bullet(
                        Text(
                            "If glucose or Trio's forecast drops below \(lowThresholdText), Trio stops basal and the test ends."
                        )
                    )
                    bullet(Text("Your usual dosing mode returns when the test ends."))
                }

                SettingsTestPageBlocker(blocker: state.startBlocker)
            } footer: {
                SettingsTestPageFooter(blocker: state.startBlocker, back: { state.previousCheckPage() }) {
                    Button {
                        state.requestStart()
                    } label: {
                        // A non-breaking hyphen, so a label that wraps keeps "4-Hour" whole, centered as on one line.
                        Text("Start \(state.selectedHours)\u{2011}Hour Fast")
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.testPrimary)
                    .disabled(!state.readyToStart)
                    // On the button it confirms, as the other steps' dialogs are.
                    .alert("Start the fast?", isPresented: $state.showStartConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Start") { state.confirmStart() }
                    } message: {
                        Text(
                            "Trio switches to Basal Testing for \(state.selectedHours) hours and then returns to \(state.currentMode.displayName). Don't eat or bolus until it ends, unless you need to treat a low."
                        )
                    }
                }
            }
        }

        /// Basal Testing's own line, 72 mg/dL, or the user's low threshold in blue when theirs is higher.
        private var lowThresholdText: Text {
            let text = Text(verbatim: state.formatWithUnits(state.lowThreshold))
            return state.lowThresholdFromSettings ? text.foregroundStyle(Color.accentColor) : text
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
}
