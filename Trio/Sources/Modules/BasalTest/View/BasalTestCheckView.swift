import SwiftUI

extension BasalTest {
    struct CheckView: View {
        @Bindable var state: StateModel

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        /// Whether the passed checks are shown one by one.
        @State private var showsPassedChecks = false

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
                    items: Self.steps(hours: state.selectedHours)
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

                SettingsTestCard(title: String(localized: "How long to fast")) {
                    hoursPicker
                    plannedWindowText
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsTestDocsQuote(text: Docs.testTimesOfDaySeparately)
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
            } footer: {
                // Why Start can't be tapped yet, where the eye goes to tap it.
                if let blocker = state.startBlocker {
                    Label {
                        Text(blocker)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    state.requestStart()
                } label: {
                    Text("Start \(state.selectedHours)-Hour Fast")
                }
                .buttonStyle(.testPrimary)
                .disabled(!state.readyToStart)
            }
            .alert("Start the fast?", isPresented: $state.showStartConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Start") { state.confirmStart() }
            } message: {
                Text(
                    "Trio switches to Basal Testing for \(state.selectedHours) hours and then returns to \(state.currentMode.displayName). Don't eat or bolus until it ends, unless you need to treat a low."
                )
            }
        }

        // MARK: - Steps

        /// Every step, for the steps sheet, with the fast as long as the `hours` picked on this screen.
        static func steps(hours: Int) -> [SettingsTestStepItem<Step>] {
            [
                .init(
                    step: .check,
                    detail: Text("The checks on this screen. Start turns on once each one passes.")
                ),
                .init(
                    step: .fast,
                    detail: Text(
                        "\(hours) hours in Basal Testing. Don't eat or bolus until it ends, unless you need to treat a low."
                    )
                ),
                .init(
                    step: .result,
                    detail: Text("Whether glucose stayed steady, or which way your basal leans for the hours it covered.")
                )
            ]
        }

        // MARK: - Pieces

        private func checkRow(for check: StateModel.Check) -> some View {
            SettingsTestCheckRow(title: check.title, detail: check.detail, state: check.state, info: check.info)
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
        private var plannedWindowText: Text {
            let window = state.plannedWindow
            let times =
                "\(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))"
            var text = Text("This fast: \(times)")
            for (index, entry) in window.covered.enumerated() {
                let span = SettingsTestSchedule.spanText(of: entry, inSentence: true)
                let rate = entry.value.formatted(.number.precision(.fractionLength(2)))
                text = text
                    + Text(verbatim: index == 0 ? " · " : ", ")
                    + (index == 0 ? Text("covers \(span) at ") : Text(verbatim: "\(span) at "))
                    + Text(verbatim: "\(rate) U/h").foregroundStyle(Color.accentColor)
            }
            return text
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
