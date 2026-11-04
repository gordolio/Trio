import SwiftUI

extension ISFTest {
    /// Below the docs' 150: the tablets that bring glucose up to it, then, once they are taken, glucose leveling off
    /// before the dose.
    struct RaiseView: View {
        @Bindable var state: StateModel

        @State private var showsCancelConfirmation = false

        private var tabletsTaken: Bool { state.test?.tabletsTakenAt != nil }

        var body: some View {
            SettingsTestScreen(paintsBackground: false) {
                if tabletsTaken {
                    levelingCard
                } else {
                    SettingsTestCard {
                        SettingsTestDocsQuote(text: Docs.chooseTestingTime)
                    }

                    SettingsTestCard(title: String(localized: "Your glucose tablets")) {
                        CarbRatioCalibration.GlucoseTabletSelector(selectedBrand: $state.selectedBrand)
                    }

                    if state.noTabletsReason == .noRecentReading {
                        SettingsTestCard {
                            WaitingRow.recentReading
                        }
                    } else if let message = state.noTabletsMessage {
                        SettingsTestCard {
                            Text(message)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let working = tabletWorking {
                        formulaCard(for: working)
                    }
                }

                SettingsTestCard {
                    Label {
                        Text("Don't log them as carbs: logging carbs ends the test.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    if let deadline = state.doseDeadlineText {
                        Text(deadline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                if tabletsTaken {
                    Button("Work Out My Dose") { state.workOutDose() }
                        .buttonStyle(.testPrimary)
                        .disabled(!state.canDose)
                } else {
                    Button("I've Taken Them") { state.tabletsTaken() }
                        .buttonStyle(.testPrimary)
                        .disabled(state.tabletCount == 0)
                    Button("Skip, Dose Now") { state.skipTablets() }
                        .buttonStyle(.testSecondary)
                }
                // Before the bolus, so Basal Testing can be turned off from this step too.
                Button("Cancel Test") { showsCancelConfirmation = true }
                    .buttonStyle(.testSecondary)
                    // On the button, so where the dialog shows as a popover it points at the button.
                    .confirmationDialog("Cancel the test?", isPresented: $showsCancelConfirmation, titleVisibility: .visible) {
                        Button("Cancel Test", role: .destructive) { state.discard() }
                        Button("Keep Going", role: .cancel) {}
                    } message: {
                        Text("Your usual dosing mode comes back, and nothing is saved.")
                    }
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await state.checkRunningTest() }
            }
        }

        // MARK: - Tablets

        /// The numbers behind the tablet count, as the formula card shows them.
        private struct TabletWorking {
            /// mg/dL
            let glucose: Int
            /// Grams per unit
            let carbRatio: Decimal
            /// mg/dL per unit
            let isf: Decimal
            /// Grams
            let carbs: Decimal
            let count: Int
        }

        /// Nil until there are tablets to count.
        private var tabletWorking: TabletWorking? {
            guard let test = state.test, let glucose = state.doseGlucose, let ratio = test.carbRatio,
                  state.tabletCount > 0
            else { return nil }
            return TabletWorking(
                glucose: glucose,
                carbRatio: ratio,
                isf: test.isf,
                carbs: state.tabletCarbsNeeded,
                count: state.tabletCount
            )
        }

        /// The docs' 150 − Current = Rise, then Rise × CR ÷ ISF = grams, with the carb ratio and ISF in blue. Two lines,
        /// so the formula fits an SE's width; the count of tablets is the conclusion under it.
        private func formulaCard(for working: TabletWorking) -> some View {
            let units = state.glucoseUnits.rawValue
            let rise = Config.docsStartAim - working.glucose

            let aim = SettingsTestFormulaTerm(
                label: String(localized: "Aim"),
                value: state.format(Config.docsStartAim),
                unit: units,
                fromSettings: false
            )
            let current = SettingsTestFormulaTerm(
                label: String(localized: "Current"),
                value: state.format(working.glucose),
                unit: units,
                fromSettings: false
            )
            let riseTerm = SettingsTestFormulaTerm(
                label: String(localized: "Rise"),
                value: state.format(rise),
                unit: units,
                fromSettings: false,
                approximate: ISFTestEvaluator.isApproximate(Decimal(rise), fractionDigits: 0, units: state.glucoseUnits)
            )
            let ratio = SettingsTestFormulaTerm(
                label: String(localized: "CR"),
                value: working.carbRatio.formatted(.number.precision(.fractionLength(0 ... 1))),
                unit: "g/U",
                fromSettings: true
            )
            let isf = SettingsTestFormulaTerm(
                label: String(localized: "ISF"),
                value: state.formatISF(working.isf),
                unit: "\(units)/U",
                fromSettings: true
            )
            let carbs = SettingsTestFormulaTerm(
                label: String(localized: "Carbs"),
                value: working.carbs.formatted(.number.precision(.fractionLength(0 ... 1))),
                unit: "g",
                fromSettings: false,
                approximate: state.tabletCarbsAreApproximate
            )
            return SettingsTestFormulaCard(
                title: String(localized: "How many tablets"),
                rows: [
                    [.term(aim), .op("−"), .term(current)],
                    [.term(riseTerm), .op("×"), .term(ratio), .op("÷"), .term(isf)]
                ],
                result: [riseTerm, carbs],
                conclusion: countText(working.count)
            )
        }

        /// "= 2 tablets of Dex4 (4 g each)".
        private func countText(_ count: Int) -> Text {
            let brand = state.selectedBrand.displayName
            let each = state.selectedBrand.carbsPerTablet.formatted(.number.precision(.fractionLength(0 ... 2)))
            if count == 1 {
                return Text("= \(Text("1 tablet").bold()) of \(brand) (\(each) g each)")
            }
            return Text("= \(Text("\(count) tablets").bold()) of \(brand) (\(each) g each)")
        }

        // MARK: - Leveling off

        /// After the tablets: the CGM's arrow and the last readings, until glucose has risen from them and the arrow is
        /// flat (or the CGM gives none).
        private var levelingCard: some View {
            LevelingCard(
                state: state,
                title: ISFTestEvaluator.levelingTitle(phase: state.test?.phase ?? .raising, tabletsActed: state.tabletsActed),
                status: levelingStatus
            )
        }

        /// What the readings mean for the dose, once there is a recent reading: carbs on board read as none, then glucose
        /// risen from the tablets, so a flat reading from before they acted can't unlock it, then leveled off.
        private var levelingStatus: String {
            if state.canDose {
                return state.trendArrow == nil
                    ? String(localized: "Your CGM gives no arrow, so check that the readings have leveled off.")
                    : String(localized: "Your glucose has leveled off.")
            }
            // Carbs on board hold the dose on this path too, and unread they aren't known to be none.
            if state.currentCOB == nil {
                return String(localized: "Waiting for Trio to read carbs on board")
            }
            if !ISFTestEvaluator.carbsAllowDose(state.currentCOB) {
                return String(
                    localized: "Carbs are on board, so the test can't be judged. The docs test ISF with no carbs on board."
                )
            }
            if !state.tabletsActed {
                return String(localized: "Waiting for your glucose to rise from the tablets.")
            }
            return String(localized: "Work Out My Dose turns on once the arrow is flat.")
        }
    }
}
