import SwiftUI

extension CarbRatioTest {
    /// After Begin: SMBs are off, and the test waits for Trio's first loop in Basal Testing and, when it waits for it,
    /// for insulin on board to come under the test's line. A bolus given meanwhile is shown here and is never the test's.
    /// Once the time for it is up with insulin on board still over the line, the screen asks whether to count it and go
    /// on, or cancel. As the ISF test's Settle step.
    struct SettleView: View {
        @Bindable var state: StateModel

        @State private var showsCancelConfirmation = false

        var body: some View {
            // Minutes are all the time left needs, so it ticks once a minute.
            TimelineView(.everyMinute) { _ in
                SettingsTestScreen(paintsBackground: false) {
                    SettingsTestHeader(
                        icon: Step.settle.iconName,
                        title: String(localized: "Settling"),
                        subtitle: state.settleLine
                    )

                    SettingsTestCard {
                        loopRow
                        readingsRow
                        if let tempBasalRow {
                            tempBasalRow
                        }
                        if state.settleShowsIOB {
                            iobRow
                        }
                        // From the time now, not the minute's tick, which can predate Begin.
                        if let timeLeft = timeLeftText(now: Date()) {
                            Text(timeLeft)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !state.settlingBoluses.isEmpty {
                        SettingsTestCard {
                            ForEach(state.settlingBoluses, id: \.date) { bolus in
                                Text(strayBolusText(bolus))
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let question = state.settleTimeUpQuestion {
                        SettingsTestCard {
                            Text(question)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let noLoop = state.settleNoLoopMessage {
                        SettingsTestCard {
                            Label {
                                Text(noLoop)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }

                    // Not yet: the tablets come with the bolus, on the Dose step.
                    SettingsTestCard {
                        Label {
                            Text("Don't take the tablets yet. The Dose step says when.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "nosign")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                } footer: {
                    if state.settleTimeUpQuestion != nil {
                        Button("Count It and Go On") { state.countAndGoOn() }
                            .buttonStyle(.testPrimary)
                            .disabled(state.isEnding)
                    }
                    Button("Cancel Test") { showsCancelConfirmation = true }
                        .buttonStyle(.testSecondary)
                        // Off while the test ends.
                        .disabled(state.isEnding)
                        // On the button, so where the dialog shows as a popover it points at the button.
                        .confirmationDialog(
                            "Cancel the test?",
                            isPresented: $showsCancelConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Cancel Test", role: .destructive) { state.discard() }
                            Button("Keep Going", role: .cancel) {}
                        } message: {
                            Text("Your usual dosing mode comes back, and nothing is saved.")
                        }
                }
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await state.checkRunningTest() }
            }
        }

        // MARK: - Rows

        /// Trio's first loop in Basal Testing: waiting, then the time it ran, or, once the time is up without one, not yet.
        private var loopRow: some View {
            let detail: String
            let rowState: SettingsTestCheckState
            if let loopedAt = state.settleLoopedAt {
                detail = String(localized: "Done at \(loopedAt.formatted(date: .omitted, time: .shortened))")
                rowState = .passed
            } else if state.settleNoLoopMessage != nil {
                detail = String(localized: "Not yet")
                rowState = .warning
            } else {
                detail = String(localized: "Waiting")
                rowState = .pending
            }
            return SettingsTestCheckRow(
                title: String(localized: "Trio's first loop in Basal Testing"),
                detail: detail,
                state: rowState
            )
        }

        /// The CGM readings since Trio's first loop in Basal Testing: waiting before the loop, then "1 of 3" and done, or,
        /// once the time is up without enough of them, not done.
        private var readingsRow: some View {
            let detail: String
            let rowState: SettingsTestCheckState
            if case .tooFewReadings = state.settling {
                detail = state.settleReadingsText ?? String(localized: "Not yet")
                rowState = .warning
            } else if let text = state.settleReadingsText {
                detail = text
                rowState = (state.settleReadings ?? 0) >= Config.settleReadings ? .passed : .pending
            } else {
                detail = String(localized: "Waiting")
                rowState = .pending
            }
            return SettingsTestCheckRow(
                title: String(localized: "Glucose readings with SMBs off"),
                detail: detail,
                state: rowState
            )
        }

        /// Shown only while a temp basal runs on the pump, which settling waits to end.
        private var tempBasalRow: SettingsTestCheckRow? {
            let timedOut: Bool
            if case .tempBasalRunning = state.settling { timedOut = true } else { timedOut = false }
            guard timedOut || state.settleTempBasalRunning else { return nil }
            return SettingsTestCheckRow(
                title: String(localized: "No temp basal running"),
                detail: timedOut ? String(localized: "Still running") : String(localized: "Waiting for it to end"),
                state: timedOut ? .warning : .pending
            )
        }

        /// Insulin on board against the line, done once it is under it, and waiting while Trio hasn't read it.
        @ViewBuilder private var iobRow: some View {
            if let line = state.test?.iobLine {
                let detail = state.currentIOB.map { current in
                    let iob = SettingsTestFormat.keepTogether(state.formatSignedUnits(current), unit: "U")
                    return String(localized: "\(iob), line \(state.lineText(line))")
                } ?? String(localized: "Waiting for Trio's insulin on board")
                SettingsTestCheckRow(
                    title: String(localized: "Insulin on board"),
                    detail: detail,
                    state: state.settleWaitsForIOB ? .pending : .passed
                )
            }
        }

        /// "Up to 42 min more", while settling waits for insulin on board and there is time left for it.
        private func timeLeftText(now: Date) -> String? {
            guard let test = state.test, state.settleWaitsForIOB, state.settleTimeUpQuestion == nil,
                  state.settleNoLoopMessage == nil
            else { return nil }
            let minutes = ISFTestEvaluator.settleMinutesLeft(startedAt: test.startedAt, now: now)
            guard minutes > 0 else { return nil }
            return String(localized: "Up to \(minutes) min more")
        }

        /// A bolus given while settling: an SMB Trio decided before Begin, or one given by hand.
        private func strayBolusText(_ bolus: ISFTestSettlingBolus) -> String {
            let units = SettingsTestFormat.keepTogether(state.formatUnits(bolus.units), unit: "U")
            return bolus.isSMB
                ? String(localized: "Trio gave \(units) (an SMB) as the test began. It's in your insulin on board.")
                : String(localized: "A bolus of \(units) was given during settling. It's in your insulin on board.")
        }
    }
}
