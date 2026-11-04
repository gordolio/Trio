import SwiftUI

extension ISFTest {
    /// Before Begin: the app facts that must hold, folded into one line once they pass, then the readings that only
    /// inform, one line each, with their details one tap away, and, when insulin on board is over the test's line, how
    /// the test should handle it.
    struct CheckView: View {
        @Bindable var state: StateModel

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

                if case let .choice(line) = state.iobDecision, let dose = state.expectedDose {
                    iobChoiceCard(line: line, dose: dose)
                }

                SettingsTestCard(title: String(localized: "While Basal Testing is on")) {
                    bullet(Text("Trio won't correct highs, give SMBs, or adjust for sensitivity."))
                    bullet(Text("If Trio suspends insulin for a low, the test ends: treat the low as usual."))
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

        // MARK: - Insulin on board

        /// Why insulin on board over the line matters, with the line in blue because it comes from the user's settings,
        /// and the two ways to handle it, the docs' way first and picked.
        private func iobChoiceCard(line: Decimal, dose: Decimal) -> some View {
            let lineText = Text(verbatim: state.lineText(line)).foregroundStyle(Color.accentColor)
            // The card shows only for a choice, which needs insulin on board read.
            let current = state.currentIOB ?? 0
            let iob = SettingsTestFormat.keepTogether(state.formatSignedUnits(current), unit: "U")
            let doseText = SettingsTestFormat.keepTogether(state.formatUnits(dose), unit: "U")
            let held = current < 0
            let explanation = held
                ? Text(
                    "Your insulin on board is \(iob): Trio held back basal recently. The test's dose is about \(doseText), and more than \(lineText) either way (\(state.stepPercent)% of it, the docs' smallest ISF change) can sway the result."
                )
                : Text(
                    "\(iob) is still working from an earlier dose or SMB. The test's dose is about \(doseText), and more than \(lineText) on board (\(state.stepPercent)% of it, the docs' smallest ISF change) can sway the result."
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
                    badge: Text("The docs' way"),
                    detail: waitDetail,
                    isSelected: state.iobChoice == .wait
                ) { state.iobChoice = .wait }
                IOBOption(
                    title: Text("Count It"),
                    badge: nil,
                    detail: Text("Begin now. Your dose takes off what's on board, and the result counts it with your bolus."),
                    isSelected: state.iobChoice == .count
                ) { state.iobChoice = .count }
            }
        }

        // MARK: - Pieces

        private func checkRow(for check: StateModel.Check) -> some View {
            SettingsTestCheckRow(title: check.title, detail: check.detail, state: check.state, info: check.info)
        }

        /// The reading on one line, and under it the short line the user needs before Start, if the row has one.
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

    /// One way to handle insulin on board: a selectable row with its title, an optional badge and what it does, picked
    /// with a filled circle and an accent outline, as the tablet brands are.
    private struct IOBOption: View {
        let title: Text
        let badge: Text?
        let detail: Text
        let isSelected: Bool
        let select: () -> Void

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        if dynamicTypeSize.isAccessibilitySize {
                            // A capsule wraps its words inside it here, so the badge is a line of its own under the title.
                            titleText
                            if let badge {
                                badge
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Self.badgeText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    titleText
                                    badgeView
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    titleText
                                    badgeView
                                }
                            }
                        }
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

        private var titleText: some View {
            title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
        }

        /// The darker blue the secondary buttons' text uses on the same tinted fill, 4.5:1 or more in both modes; the tint
        /// itself measured under 3:1 in light mode.
        private static var badgeText: Color {
            Color(uiColor: SettingsTestSecondaryButtonStyle.textColor)
        }

        @ViewBuilder private var badgeView: some View {
            if let badge {
                badge
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.badgeText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
    }
}
