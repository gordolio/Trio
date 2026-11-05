import Combine
import CoreData
import Foundation
import Observation
import SwiftUI

extension ISFTest {
    /// The pages of the Check step, one question each: the checks, insulin on board (only when it is over the test's
    /// line), and the summary with Begin. Screen state, never saved: a relaunch opens the checks.
    enum CheckPage: CaseIterable, Hashable {
        case checks
        case iob
        case ready
    }

    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        /// What runs the test, in the service: the screen shows its state (`apply`) and passes the user's actions on. The
        /// service's (`subscribe`), or one a test sets.
        @ObservationIgnored var runner: ISFTestRunning?
        /// Told when a notice-opened screen sends the user to Treatments (`sendToTreatments`). Settable for tests; lazy, so
        /// the shared one is read on the main actor, where it lives.
        @ObservationIgnored @MainActor lazy var opener = SettingsTestScreenOpener.shared
        /// What `refresh` reads: the provider, or what a test sets.
        @ObservationIgnored var screenReads: ISFTestProvider?
        private var reads: ISFTestProvider { screenReads ?? provider }

        /// How far back the screen reads glucose: the longest a test runs, 90 minutes for the bolus and 4 hours after
        /// it, with time to spare.
        private static let recentReadingsMinutes = 6 * 60

        // MARK: - State

        /// The test in progress or just finished, as the runner saved it. `nil` while the user is still getting ready.
        private(set) var test: ISFTestState?

        /// Newest first.
        private(set) var recentReadings: [BasalTestReading] = []
        /// Nil while Trio hasn't worked insulin on board out. While the runner reports settling, the one its last check
        /// read (`ISFTestSettlingProgress.iob`), so the Settle step's row and question agree with the step it shows;
        /// otherwise the one `refresh` read.
        var currentIOB: Decimal? { settling == nil ? readIOB : settleIOB }
        /// Insulin on board as `refresh` last read it.
        private var readIOB: Decimal?
        /// Insulin on board as settling's last check read it. Set only by `apply`.
        private var settleIOB: Decimal?
        /// Insulin on board for a counted dose, from Trio's newest determination of the last 12 minutes
        /// (`ISFTestEvaluator.recentIOB`), as the runner last read it. Nil when there is none, or in a test that doesn't
        /// count it.
        private(set) var doseIOB: Decimal?
        /// Carbs on board from Trio's newest determination of the last 12 minutes (`ISFTestEvaluator.recentCOB`). Nil
        /// while there is none that recent: unread is not none.
        private(set) var currentCOB: Decimal?
        private(set) var hasActiveAdjustment = false
        private(set) var hasPumpSetTempBasal = false
        /// What the pump is doing with basal now. Nil without a pump, or when its state can't be read.
        private(set) var pumpDelivery: ISFTestPumpDelivery?
        private(set) var hasDevices = true
        /// The CGM's own trend arrow for the newest reading.
        private(set) var trendDirection: BloodGlucose.Direction?
        /// The kind of settings test running, if any. Only one can run at a time.
        private(set) var activeSessionKind: SettingsTestKind?
        /// The session running and the one the service last ended on its own, as the service last said (`showSession`).
        /// Nil until the screen has read them.
        private(set) var serviceSession: (activeID: UUID?, lastEndID: UUID?)?
        /// The ISF schedule now, in mg/dL per unit, for the hours the Check screen says the test will cover.
        private(set) var isfSchedule: [SettingsTestScheduleEntry] = []
        /// The settings in force now, for the Check screen. A running test uses the ones it saved at Start.
        private(set) var isfNow: Decimal?
        private(set) var targetNow: Decimal?
        /// What the newest basal test says about the basal this test runs on. It only informs.
        private(set) var basalGate: SettingsTestSchedule.BasalGate = .noSteadyTest

        /// The tablets picked on the Raise step.
        var selectedBrand: GlucoseTabletBrand = .dex4

        /// How the test handles insulin on board over its line, as picked on the Check screen. The docs' way first.
        var iobChoice: ISFTestIOBHandling = .wait
        /// The Check step's page, as the user moved to it (`shownCheckPage` is the one shown).
        var checkPage: CheckPage = .checks
        /// Where settling is, from its last check. Nil when the test isn't settling, or before the first check.
        private(set) var settling: ISFTestSettling?
        /// The boluses given while the test settles, oldest first (`ISFTestEvaluator.settlingBoluses`).
        private(set) var settlingBoluses: [ISFTestSettlingBolus] = []
        /// How many CGM readings came after Trio's first loop in Basal Testing, from settling's last check
        /// (`ISFTestEvaluator.readingsAfterLoop`). Nil before that loop, and when the test isn't settling.
        private(set) var settleReadings: Int?
        /// Whether a temp basal was running on the pump at settling's last check, which holds it up.
        private(set) var settleTempBasalRunning = false

        var errorMessage: String?
        var showStartConfirmation = false
        var showStopOptions = false

        @ObservationIgnored private var dataSubscriptions = Set<AnyCancellable>()
        /// Each refresh's number, in the order they began, and the newest one shown (`refresh`). Main actor only.
        @ObservationIgnored private var refreshesBegun = 0
        @ObservationIgnored private var newestRefreshShown = 0

        // MARK: - Units

        var glucoseUnits: GlucoseUnits {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.units ?? .mgdL
        }

        func format(_ mgdl: Int) -> String {
            mgdl.formatted(for: glucoseUnits)
        }

        /// "212 mg/dL", kept on one line where it sits in a sentence.
        func formatWithUnits(_ mgdl: Int) -> String {
            SettingsTestFormat.keepTogether(format(mgdl), unit: glucoseUnits.rawValue)
        }

        /// The ISF, stored in mg/dL per unit, in the user's units.
        func formatISF(_ isf: Decimal) -> String {
            isf.formattedISF(for: glucoseUnits)
        }

        /// A target in mg/dL, which may have a fraction, in the user's units.
        func formatTarget(_ mgdl: Decimal) -> String {
            mgdl.formatted(for: glucoseUnits)
        }

        /// A change in glucose with its sign, e.g. "+12" or "-0.7", in the user's units.
        func formatChange(_ mgdl: Int) -> String {
            let value = glucoseUnits == .mmolL ? Double(truncating: abs(mgdl).asMmolL as NSNumber) : Double(abs(mgdl))
            let text = glucoseUnits == .mmolL ? String(format: "%.1f", value) : "\(Int(value))"
            return (mgdl < 0 ? "-" : "+") + text
        }

        /// Insulin units to 2 decimals, rounded half up as the comparisons with them are, e.g. "2.24"
        /// (`ISFTestEvaluator.shownUnits`).
        func formatUnits(_ units: Decimal) -> String {
            ISFTestEvaluator.shownUnits(units)
        }

        /// Insulin units to 2 decimals with a minus sign, not a hyphen, when below zero, e.g. "−0.30".
        func formatSignedUnits(_ units: Decimal) -> String {
            (units < 0 ? "\u{2212}" : "") + formatUnits(abs(units))
        }

        /// A drop per unit, stored in mg/dL per unit, in the user's units (`ISFTestEvaluator.perUnitText`).
        func formatPerUnit(_ mgdlPerUnit: Decimal) -> String {
            ISFTestEvaluator.perUnitText(mgdlPerUnit, units: glucoseUnits)
        }

        /// A share of the ISF as a whole percent with its sign, rounded toward zero (`ISFTestEvaluator.percentText`).
        func formatPercent(_ share: Decimal) -> String {
            ISFTestEvaluator.percentText(share)
        }

        /// The docs' smallest ISF change as a whole percent.
        var stepPercent: Int {
            NSDecimalNumber(decimal: Config.docsSmallestStep * 100).intValue
        }

        /// Grams of glucose tablets, e.g. "12" or "7.5".
        func formatGrams(_ grams: Decimal) -> String {
            grams.formatted(.number.precision(.fractionLength(0 ... 2)))
        }

        var currentMode: DosingMode {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.dosingMode ?? .open
        }

        // MARK: - Step

        var step: Step {
            switch test?.phase {
            case .settling: return .settle
            case .raising: return .raise
            case .dosing: return .dose
            case .waiting: return .wait
            case .finished: return .result
            case nil: return .check
            }
        }

        // MARK: - Readings

        var currentGlucose: Int? { recentReadings.first?.glucose }

        var readingIsStale: Bool {
            guard let latest = recentReadings.first?.date else { return true }
            return Date().timeIntervalSince(latest) > ISFTestEvaluator.arrowMaxAge
        }

        /// The Wait step's "Now", which its "Change" is worked out from: the newest reading while it is recent, nil once it
        /// is out of date (`readingIsStale`), so a CGM that stopped doesn't leave an old reading standing as now.
        var glucoseNow: Int? {
            readingIsStale ? nil : currentGlucose
        }

        /// What the Dose step reads to work out whether the dose can be given, as one value, at this moment: the rules
        /// that judge it take it whole (`ISFTestDoseInputs`), so a runner with the screen closed judges the same.
        var doseInputs: ISFTestDoseInputs {
            ISFTestDoseInputs(
                readings: recentReadings,
                direction: trendDirection,
                iob: currentIOB,
                doseIOB: doseIOB,
                cob: currentCOB,
                increment: bolusIncrement,
                now: Date()
            )
        }

        /// The glucose the dose and the tablets are worked out from: the mean of the last 3 readings, nil when the
        /// newest is older than `BasalTest.Config.endReadingMaxAge` (`ISFTestEvaluator.doseGlucose`).
        var doseGlucose: Int? {
            ISFTestEvaluator.doseGlucose(doseInputs)
        }

        /// The CGM's own arrow for a recent reading. Nil when it gave none (`ISFTestEvaluator.shownDirection`).
        private var shownDirection: BloodGlucose.Direction? {
            ISFTestEvaluator.shownDirection(doseInputs)
        }

        /// The arrow as the screen shows it, if the CGM gave one for a recent reading.
        var trendArrow: String? {
            guard let direction = shownDirection else { return nil }
            switch direction {
            case .none,
                 .notComputable,
                 .rateOutOfRange: return nil
            default: return direction.symbol
            }
        }

        // MARK: - Readiness

        var modeAvailable: Bool { currentMode != .basalTesting }

        struct Check: Identifiable {
            let id: String
            let title: String
            /// What a check that passes or fails says beyond its title, or, on a row that informs, the short line shown
            /// under it. Nil when the title says it all.
            var detail: String?
            /// What a reading shows on its one line, e.g. "212 mg/dL".
            var value: String?
            let state: SettingsTestCheckState
            /// Why the row is there. Its info button opens it.
            let info: SettingsTestInfo
        }

        /// Facts about the app that have to be true before the test starts, and insulin on board when it is more than the
        /// test's whole dose.
        var blockingChecks: [Check] {
            // Another test running comes first: its Basal Testing fails the mode check too, and the footer names the test.
            var checks = [otherTestCheck, devicesCheck, pumpSuspendedCheck, adjustmentsCheck, pumpTempBasalCheck, modeCheck]
            // Read, carbs on board are a docs rule that holds Begin up; not read yet, the row informs instead.
            if let cobCheck {
                checks.append(cobCheck)
            }
            if let noDoseCheck {
                checks.append(noDoseCheck)
            }
            if let iobBlockCheck {
                checks.append(iobBlockCheck)
            }
            if let isfChangeBlockCheck {
                checks.append(isfChangeBlockCheck)
            }
            return checks
        }

        /// Readings that go with the docs' words but set no rule, so they never hold up the start.
        var informingChecks: [Check] {
            var rows = [glucoseCheck, trendCheck]
            // When insulin on board holds Begin up, its row is the one under "Ready to start?".
            if iobDecision != .blocked {
                rows.append(iobCheck)
            }
            if let cobUnreadCheck {
                rows.append(cobUnreadCheck)
            }
            rows.append(basalCheck)
            if let isfChangeCheck {
                rows.append(isfChangeCheck)
            }
            if let lowThresholdCheck {
                rows.append(lowThresholdCheck)
            }
            return rows
        }

        /// What the test does first from the glucose now, as Start would decide it. Nil without a recent reading or a
        /// target.
        var startPath: ISFTestStartPath? {
            ISFTestEvaluator.startPath(glucose: doseGlucose, target: targetNow)
        }

        var readyToStart: Bool {
            blockingChecks.allSatisfy { $0.state == .passed }
        }

        /// The docs' dose the test expects from the glucose and settings now, which insulin on board is measured
        /// against. Nil when there is none to work out.
        var expectedDose: Decimal? {
            ISFTestEvaluator.expectedDose(startPath: startPath, glucose: doseGlucose, target: targetNow, isf: isfNow)
        }

        /// What insulin on board now means for the test. Nil without an expected dose.
        var iobDecision: ISFTestIOBDecision? {
            ISFTestEvaluator.iobDecision(iob: currentIOB, expectedDose: expectedDose)
        }

        /// Shown one by one, because each says what to do.
        var failingChecks: [Check] { blockingChecks.filter { $0.state != .passed } }

        /// Folded into one line on the Check screen.
        var passingChecks: [Check] { blockingChecks.filter { $0.state == .passed } }

        /// Why Start can't be tapped yet: what the first check that fails says.
        var startBlocker: String? {
            guard let check = failingChecks.first else { return nil }
            return check.detail ?? check.title
        }

        /// The ISF schedule entries the docs' 4 hours from now cover.
        var plannedEntries: [SettingsTestScheduleEntry] {
            let now = Date()
            return ISFTestEvaluator.coveredEntries(isfSchedule, from: now, to: now.addingTimeInterval(Config.docsWait)) ?? []
        }

        /// Whether the 4 hours from now cover more than one ISF value (R3). The row informs while a bolus moment the test
        /// can reach clears the change; when none does, it holds Begin up instead (`isfChangeBlocksBegin`).
        var crossesISFChange: Bool {
            ISFTestEvaluator.crossesISFChange(isfSchedule, from: Date(), for: Config.docsWait)
        }

        /// Whether the ISF schedule holds Begin up, a docs rule ("Test one time period at a time"): no bolus moment the test
        /// can reach has its 4 hours on one ISF value (`ISFTestEvaluator.isfChangeBlocksBegin`), so the Dose step could
        /// only end the test.
        var isfChangeBlocksBegin: Bool {
            ISFTestEvaluator.isfChangeBlocksBegin(isfSchedule, now: Date())
        }

        /// The informing rows that warn, with an orange triangle, because they are easy to miss. None blocks the start.
        var warnings: Set<ISFTestWarning> {
            ISFTestEvaluator.warnings(
                basalGate: basalGate,
                crossesISFChange: crossesISFChange,
                lowThresholdAtTarget: ISFTestEvaluator.lowThresholdAtTarget(threshold: lowThreshold, target: targetNow)
            )
        }

        /// The low threshold Basal Testing suspends at, in mg/dL: the user's, or 72 if that is higher, as upstream's
        /// Basal Testing clamps it.
        var lowThreshold: Decimal {
            let manager: SettingsManager? = settingsManager
            let preferences = manager?.preferences ?? Preferences()
            return preferences.clamped(for: .basalTesting).threshold_setting
        }

        /// The steps the step bar shows as skipped, not done.
        var skippedSteps: Set<Step> {
            ISFTestEvaluator.skippedSteps(of: test)
        }

        // MARK: Rows that block

        private var devicesCheck: Check {
            Check(
                id: "devices",
                title: String(localized: "CGM and pump connected"),
                detail: hasDevices ? nil : String(localized: "Connect a CGM and a pump first"),
                state: hasDevices ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "CGM and pump connected"),
                    body: String(
                        localized: "Trio needs your CGM to watch glucose and your pump to deliver the bolus and your basal while the test runs."
                    )
                )
            )
        }

        /// Basal has to be going in for the test: a suspended pump gives neither basal nor the bolus.
        private var pumpSuspendedCheck: Check {
            let blocks = ISFTestEvaluator.pumpBlocksBegin(pumpDelivery)
            return Check(
                id: "pumpSuspended",
                title: String(localized: "Pump not suspended"),
                detail: blocks ? String(localized: "Resume insulin on your pump first") : nil,
                state: blocks ? .failed : .passed,
                info: SettingsTestInfo(
                    title: String(localized: "Pump not suspended"),
                    body: String(
                        localized: "While insulin is suspended, your pump gives no basal and no bolus, so the test can't measure what one bolus does. A suspend, an alarm, or a site or reservoir change during the test ends it without a result."
                    )
                )
            )
        }

        private var adjustmentsCheck: Check {
            Check(
                id: "adjustments",
                title: String(localized: "No override or temp target"),
                detail: hasActiveAdjustment
                    ? String(localized: "End it first. Both change your basal and sensitivity")
                    : nil,
                state: hasActiveAdjustment ? .failed : .passed,
                info: SettingsTestInfo(
                    title: String(localized: "No override or temp target"),
                    body: String(
                        localized: "An override or a temp target changes how much insulin Trio gives and how it reads your sensitivity, so the test wouldn't show what your ISF does on its own."
                    ),
                    quote: "\(BasalTest.Docs.overridesChangeSettings)\n\(BasalTest.Docs.tempTargetsChangeInsulin)",
                    links: [BasalTest.Docs.overridesLink, BasalTest.Docs.tempTargetsLink]
                )
            )
        }

        private var pumpTempBasalCheck: Check {
            Check(
                id: "pumpTempBasal",
                title: String(localized: "No temp basal set on the pump"),
                detail: hasPumpSetTempBasal ? String(localized: "Cancel it on the pump first") : nil,
                state: hasPumpSetTempBasal ? .failed : .passed,
                info: SettingsTestInfo(
                    title: String(localized: "No temp basal set on the pump"),
                    body: String(
                        localized: "Basal Testing cancels a temp basal Trio set, but not one set on the pump itself. That one would keep running and change your basal during the test, so the drop wouldn't show what your ISF does on its own."
                    )
                )
            )
        }

        private var modeCheck: Check {
            Check(
                id: "mode",
                title: String(localized: "Basal Testing is off"),
                detail: modeDetail,
                state: modeAvailable ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "Basal Testing is off"),
                    body: String(
                        localized: "Trio switches itself to Basal Testing for the test and puts your usual dosing mode back afterwards, so it has to start from another mode."
                    )
                )
            )
        }

        /// Under the mode check. While another test runs, Basal Testing is that test's, so the line names it and says nothing
        /// about switching modes: a switch would end it.
        private var modeDetail: String {
            if modeAvailable { return String(localized: "\(currentMode.displayName) now. Trio returns to it after.") }
            if let running = otherRunningTest {
                return String(localized: "The \(running.title) test has Basal Testing on. It goes off when that test ends.")
            }
            return String(localized: "Switch to your usual dosing mode first, so Trio can return you to it")
        }

        /// The other settings test running now, or nil. The hub opens this screen while one does, so its steps can be read.
        var otherRunningTest: SettingsTestKind? {
            activeSessionKind.flatMap { $0 == .isf ? nil : $0 }
        }

        /// Whether the usual dosing mode is on, so the Result can say it is back. Not while Basal Testing is on, whether
        /// left on or another test's.
        var usualModeIsOn: Bool { currentMode != .basalTesting }

        private var otherTestCheck: Check {
            Check(
                id: "otherTest",
                title: String(localized: "No other test running"),
                // Not this test's own session: one open with no test of its own leaves the mode check to say the way out.
                detail: otherRunningTest.map { String(localized: "The \($0.title) test is still running. Finish it first.") },
                state: otherRunningTest == nil ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "No other test running"),
                    body: String(
                        localized: "Only one settings test can run at a time, because each one puts your settings back when it ends."
                    )
                )
            )
        }

        // MARK: Rows that inform

        // Each is one line, a label and a value; anything longer is in its info sheet. A `detail` is a short line the
        // screen shows under the row, for what the user needs before Start.

        /// The average of the last 3 readings, the number the path, the tablets and the dose use. Without a recent reading
        /// for it, the newest reading and how old it is.
        private var glucoseCheck: Check {
            let value: String
            if let average = doseGlucose {
                value = formatWithUnits(average)
            } else if let glucose = currentGlucose, let latest = recentReadings.first?.date {
                value = String(
                    localized: "\(formatWithUnits(glucose)), \(SettingsTestFormat.duration(Date().timeIntervalSince(latest))) ago"
                )
            } else {
                value = String(localized: "Waiting")
            }
            // At or below a high target, the row after this one says why there is no path.
            let path: String?
            switch startPath {
            case .raise:
                path = String(localized: "Below \(format(Config.docsStartAim)): you'll raise it with glucose tablets first")
            case .dose: path = String(localized: "Ready for the dose")
            case nil,
                 .noDose: path = nil
            }
            return Check(
                id: "glucose",
                title: String(localized: "Glucose now"),
                detail: path,
                value: value,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Glucose now"),
                    body: String(
                        localized: "The average of your last 3 CGM readings, where the test starts from. The tablets and the dose are worked out from it. Without a recent reading, this shows your newest one and how old it is. It's here for you to judge and doesn't hold up the start."
                    ),
                    reading: path,
                    quote: Docs.chooseTestingTime,
                    links: [Docs.testingMethodLink]
                )
            )
        }

        /// Shown only when glucose is at or below a target of 150 or more (`ISFTestEvaluator.noDoseBlocksBegin`): the
        /// docs' formula gives no dose, and the test's tablets, which aim for the docs' "around 150", have no higher number
        /// to aim for. It holds up Begin, so no test starts on a path where a later dose would skip the insulin on board
        /// checks.
        private var noDoseCheck: Check? {
            guard ISFTestEvaluator.noDoseBlocksBegin(startPath: startPath), let target = targetNow else { return nil }
            let targetText = SettingsTestFormat.keepTogether(formatTarget(target), unit: glucoseUnits.rawValue)
            return Check(
                id: "noDose",
                title: String(localized: "Glucose above your target"),
                detail: String(
                    localized: "Your glucose isn't above your target, and at a target of 150 or more the test has nothing to raise it to."
                ),
                state: .failed,
                info: SettingsTestInfo(
                    title: String(localized: "Glucose above your target"),
                    body: String(
                        localized: "The correction dose is your glucose minus your target, divided by your ISF, so the test needs glucose above your target, and tablets can't raise it there. \(tabletAimText)"
                    ),
                    reading: String(localized: "Your target is \(targetText)"),
                    quote: Docs.chooseTestingTime,
                    links: [Docs.testingMethodLink]
                )
            )
        }

        /// Where the test's tablets aim, and why that gives nothing to aim for at a high target. The aim is the test's,
        /// taken from the docs' "around 150"; the docs set no rule for it.
        var tabletAimText: String {
            let aim = formatWithUnits(Config.docsStartAim)
            return String(
                localized: "The test's tablets aim for around \(aim), from \"around 150 mg/dL or 8.3 mmol/L\" in Trio docs. At a target of \(aim) or more, the test has no higher number to aim for."
            )
        }

        private var trendCheck: Check {
            let value: String
            if let arrow = trendArrow {
                value = arrow
            } else {
                value = recentReadings.isEmpty || readingIsStale ? String(localized: "Waiting") : String(localized: "No arrow")
            }
            return Check(
                id: "trend",
                title: String(localized: "Trend"),
                value: value,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Trend"),
                    body: String(
                        localized: "The arrow is your CGM's own. It's here for you to judge and doesn't hold up the start."
                    )
                )
            )
        }

        /// Warns once insulin on board is over the test's line, where the page after the checks asks how to handle it.
        /// Before Trio has worked it out, it says so and doesn't hold up Begin; settling then waits for it.
        private var iobCheck: Check {
            let warns: Bool
            switch iobDecision {
            case .blocked,
                 .choice: warns = true
            case .fine,
                 nil: warns = false
            }
            return Check(
                id: "iob",
                title: String(localized: "Insulin on board"),
                value: currentIOB.map { String(localized: "\(formatSignedUnits($0)) U") } ?? String(localized: "Not read yet"),
                state: warns ? .warning : .info,
                info: iobInfo
            )
        }

        private var iobInfo: SettingsTestInfo {
            let reading = expectedDose.map { dose in
                let line = SettingsTestFormat.keepTogether(
                    formatUnits(ISFTestEvaluator.iobLine(expectedDose: dose)),
                    unit: "U"
                )
                let doseText = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
                return String(localized: "The test's dose is about \(doseText), so its line is \(line)")
            }
            return SettingsTestInfo(
                title: String(localized: "Insulin on board"),
                body: String(
                    localized: "Insulin still working from an earlier dose or SMB adds to the drop the test measures, and negative insulin on board, basal Trio held back, takes from it. More than \(stepPercent)% of the test's dose, the smallest ISF change in Trio docs, can sway the result, so you choose whether the test waits for it or counts it. More than the whole dose holds up the start."
                ),
                reading: reading,
                quote: Docs.smallChanges,
                links: [Docs.bestPracticesLink]
            )
        }

        /// Shown only when insulin on board is more than the test's whole dose: Begin waits until it has come down.
        private var iobBlockCheck: Check? {
            guard iobDecision == .blocked, let dose = expectedDose, let iob = currentIOB else { return nil }
            let doseText = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
            let detail = iob < 0
                ? String(
                    localized: "Trio held back \(formatUnits(abs(iob))) U of basal, more than the test's whole dose (\(doseText)). Begin once it has come back."
                )
                : String(
                    localized: "\(formatUnits(iob)) U is more than the test's whole dose (\(doseText)). Begin once it has come down."
                )
            return Check(
                id: "iobBlock",
                title: String(localized: "Too much insulin on board"),
                detail: detail,
                state: .failed,
                info: iobInfo
            )
        }

        // MARK: Insulin on board over the line

        /// The line, e.g. "0.10 U", kept on one line.
        func lineText(_ line: Decimal) -> String {
            SettingsTestFormat.keepTogether(formatUnits(line), unit: "U")
        }

        /// The settling allowance as the choice words it, e.g. "1 hour".
        var settleAllowanceText: String {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.hour, .minute]
            return formatter.string(from: Config.settleAllowance) ?? "\(Int(Config.settleAllowance / 60)) min"
        }

        // MARK: - Pages

        /// The pages that apply now, in order: insulin on board only when it is over the test's line, where there is a
        /// choice to make (`iobDecision` is `.choice`).
        var checkPages: [CheckPage] {
            CheckPage.allCases.filter { page in
                guard page == .iob else { return true }
                if case .choice = iobDecision { return true }
                return false
            }
        }

        /// The page shown: the one the user moved to while it applies, otherwise the one before it that does
        /// (`SettingsTestPageFlow.shown`), so the insulin on board page that stops applying hands over to the checks.
        var shownCheckPage: CheckPage {
            SettingsTestPageFlow.shown(checkPage, in: checkPages, order: CheckPage.allCases)
        }

        /// "2 of 3", for the page's heading.
        func checkPagePosition(_ page: CheckPage) -> String {
            SettingsTestPageFlow.position(of: page, in: checkPages)
        }

        /// Whether Next goes on: only while every check passes, as Begin does. A check that starts failing on a later page
        /// turns Next and Begin off there, with its sentence (`startBlocker`).
        var canGoOn: Bool { readyToStart }

        /// Next: the page after the one shown, while every check passes.
        func nextCheckPage() {
            guard canGoOn, let next = SettingsTestPageFlow.page(after: shownCheckPage, in: checkPages) else { return }
            checkPage = next
        }

        /// Back: the page before the one shown, the insulin on board page skipped when it doesn't apply.
        func previousCheckPage() {
            guard let previous = SettingsTestPageFlow.page(before: shownCheckPage, in: checkPages) else { return }
            checkPage = previous
        }

        /// One line of the Ready page's summary.
        struct SummaryRow: Equatable {
            let title: String
            let value: String
        }

        /// The Ready page's summary: what comes after settling, from the glucose now (`startPath`), the dose the test
        /// expects, and how insulin on board is handled when there was a choice to make. A row without its reading is
        /// left out.
        var readySummary: [SummaryRow] {
            var rows: [SummaryRow] = []
            switch startPath {
            case .raise:
                rows.append(SummaryRow(
                    title: String(localized: "After settling"),
                    value: String(localized: "Glucose tablets, then the dose")
                ))
            case .dose:
                rows.append(SummaryRow(title: String(localized: "After settling"), value: String(localized: "The dose")))
            case nil,
                 .noDose:
                break
            }
            if let dose = expectedDose {
                rows.append(SummaryRow(
                    title: String(localized: "Dose"),
                    value: String(localized: "About \(SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U"))")
                ))
            }
            if case .choice = iobDecision {
                rows.append(SummaryRow(
                    title: String(localized: "Insulin on board"),
                    value: iobChoice == .count ? String(localized: "Count It") : String(localized: "Wait for It")
                ))
            }
            return rows
        }

        /// The docs test ISF with no carbs on board, a docs rule, so carbs on board hold up Begin (round 13 item 2). Nil
        /// while Trio hasn't read them recently (`cobUnreadCheck` then informs).
        private var cobCheck: Check? {
            guard let cob = currentCOB else { return nil }
            let blocks = ISFTestEvaluator.carbsOnBoardBlockBegin(cob)
            let grams = cob.formatted(.number.precision(.fractionLength(0 ... 1)))
            return Check(
                id: "cob",
                title: String(localized: "No carbs on board"),
                detail: blocks ? String(localized: "\(grams) g on board. Begin once Trio counts none") : nil,
                state: blocks ? .failed : .passed,
                info: cobInfo
            )
        }

        /// Shown while none of Trio's determinations in the last 12 minutes says how many carbs are on board. It doesn't
        /// hold up Begin, as insulin on board not read yet doesn't; the Dose step waits for a read that says none.
        private var cobUnreadCheck: Check? {
            guard currentCOB == nil else { return nil }
            return Check(
                id: "cobUnread",
                title: String(localized: "Carbs on board"),
                value: String(localized: "Not read yet"),
                state: .info,
                info: cobInfo
            )
        }

        private var cobInfo: SettingsTestInfo {
            SettingsTestInfo(
                title: String(localized: "No carbs on board"),
                body: String(
                    localized: "The carbs Trio still counts as absorbing. Carbs still raising glucose hide part of the drop the test measures, so the test waits until Trio counts none."
                ),
                quote: Docs.testISFWhenFasting,
                links: [Docs.testingMethodLink]
            )
        }

        /// What the newest basal test found. A warning only, never a block (round 7 Q4), with the triangle when it isn't
        /// a steady test on an unchanged schedule.
        private var basalCheck: Check {
            Check(
                id: "basal",
                title: String(localized: "Basal test"),
                value: ISFTestEvaluator.basalGateText(basalGate),
                state: warnings.contains(.basalNotSteady) ? .warning : .info,
                info: SettingsTestInfo(
                    title: String(localized: "Basal test"),
                    body: String(
                        localized: "ISF is tested on steady basal. The test reads how far one bolus brings glucose down, and a basal that's too high or too low moves glucose on its own, which adds to that drop or hides part of it. It's here for you to judge and doesn't hold up the start."
                    ),
                    quote: Docs.basalFirst,
                    links: [Docs.whyBasalRatesMatterLink, BasalTest.Docs.fastingTestsLink]
                )
            )
        }

        /// Shown only when the 4 hours from now cover more than one ISF value, while a bolus moment the test can reach
        /// clears it (otherwise `isfChangeBlockCheck` holds Begin up).
        private var isfChangeCheck: Check? {
            guard crossesISFChange, !isfChangeBlocksBegin else { return nil }
            let entries = plannedEntries
            // The test's 4 hours, split where the ISF changes, each part with its ISF, not the whole entries they touch.
            let spans = ISFTestEvaluator.isfChangeReading(
                ISFTestEvaluator.coveredSpans(isfSchedule, from: Date(), for: Config.docsWait),
                units: glucoseUnits
            )
            return Check(
                id: "isfChange",
                title: String(localized: "ISF changes during the test"),
                value: entries.map { formatISF($0.value) }.joined(separator: ", "),
                state: warnings.contains(.isfChanges) ? .warning : .info,
                info: SettingsTestInfo(
                    title: String(localized: "ISF changes during the test"),
                    body: String(
                        localized: "The 4 hours from now cover more than one ISF. The dose and the result use the one in force at your bolus. It doesn't hold up the start."
                    ),
                    reading: String(localized: "These hours cover \(spans)"),
                    quote: Docs.testSystematically,
                    links: [Docs.bestPracticesLink]
                )
            )
        }

        /// Shown only when no bolus moment the test can reach has its 4 hours on one ISF value (`isfChangeBlocksBegin`): it
        /// holds Begin up, as the docs' rule, with the informing row's first sentence and the docs' quote.
        private var isfChangeBlockCheck: Check? {
            guard isfChangeBlocksBegin else { return nil }
            let sentence = ISFTestEvaluator.noDoseSentence(.isfChangesUntilDeadline)
            let spans = ISFTestEvaluator.isfChangeReading(
                ISFTestEvaluator.coveredSpans(isfSchedule, from: Date(), for: Config.docsWait),
                units: glucoseUnits
            )
            return Check(
                id: "isfChange",
                title: String(localized: "ISF changes during the test"),
                detail: sentence,
                state: .failed,
                info: SettingsTestInfo(
                    title: String(localized: "ISF changes during the test"),
                    body: sentence ?? "",
                    reading: String(localized: "These hours cover \(spans)"),
                    quote: Docs.testSystematically,
                    links: [Docs.bestPracticesLink]
                )
            )
        }

        /// Shown only when the low threshold Basal Testing suspends at is at or above the target: Trio's forecast after the
        /// dose heads for the target, so it may suspend right after it, and a suspend with glucose above the target gives no
        /// result. It warns and doesn't hold up the start.
        private var lowThresholdCheck: Check? {
            guard warnings.contains(.lowThreshold) else { return nil }
            let units = glucoseUnits.rawValue
            let threshold = SettingsTestFormat.keepTogether(formatTarget(lowThreshold), unit: units)
            let basalTesting = SettingsTestFormat.keepTogether(
                formatTarget(Preferences.basalTestingThreshold),
                unit: units
            )
            let target = targetNow.map { SettingsTestFormat.keepTogether(formatTarget($0), unit: units) }
            return Check(
                id: "lowThreshold",
                title: String(localized: "Low threshold"),
                detail: String(
                    localized: "Your low threshold is at or above your target, so Trio may suspend right after the dose."
                ),
                value: threshold,
                state: .warning,
                info: SettingsTestInfo(
                    title: String(localized: "Low threshold"),
                    body: String(
                        localized: "Basal Testing suspends insulin when your glucose or Trio's forecast goes below your low threshold, or \(basalTesting) if that's higher. After the dose, the forecast heads for your target. A suspend while your glucose is still above your target ends the test without a result. It doesn't hold up the start."
                    ),
                    reading: target.map { String(localized: "Your target is \($0)") }
                )
            )
        }

        // MARK: - Raise

        /// The grams of tablets that bring glucose up to the docs' 150: (150 − current) × CR ÷ ISF, with the carb ratio
        /// and ISF saved at Start. Zero at or above it, and without a reading or a carb ratio.
        var tabletCarbsNeeded: Decimal {
            guard let test, let glucose = doseGlucose, let ratio = test.carbRatio else { return 0 }
            return ISFTestEvaluator.tabletCarbs(glucose: glucose, carbRatio: ratio, isf: test.isf)
        }

        /// Whole tablets of the chosen brand that give at least `tabletCarbsNeeded`.
        var tabletCount: Int {
            ISFTestEvaluator.tablets(for: tabletCarbsNeeded, brand: selectedBrand)
        }

        /// Why there are no tablets to count, nil when there are.
        var noTabletsReason: ISFTestNoTablets? {
            ISFTestEvaluator.noTabletsReason(glucose: doseGlucose, carbRatio: test?.carbRatio)
        }

        /// What the Raise step says instead of the tablets when there are none to count.
        var noTabletsMessage: String? {
            switch noTabletsReason {
            case .noRecentReading: return String(localized: "Waiting for a recent CGM reading")
            case .noCarbRatio: return String(localized: "Trio couldn't read your carb ratio, so it can't count the tablets.")
            case .atOrAboveAim:
                return String(
                    localized: "Your glucose is already at or above \(formatWithUnits(Config.docsStartAim)), so there are no tablets to take."
                )
            case nil: return nil
            }
        }

        /// Whether the grams of tablets follow "≈": shown to 1 decimal, or worked out from values shown in mmol/L.
        var tabletCarbsAreApproximate: Bool {
            ISFTestEvaluator.isApproximate(tabletCarbsNeeded, fractionDigits: 1, units: glucoseUnits)
        }

        /// Whether tablets can raise glucose for this test: only with a target below the docs' 150. The one the Dose step
        /// works the dose out with once the test has started (`doseSettings`), the one in force now before that.
        var canRaise: Bool {
            guard let target = doseSettings?.target ?? targetNow else { return false }
            return ISFTestEvaluator.canRaise(target: target)
        }

        // MARK: - Dose

        /// The dose the Dose step shows (`ISFTestEvaluator.testDose`): the docs' correction, (glucose − target) ÷ ISF, with
        /// the target and ISF in force now (`doseSettings`); with Count It, less the insulin on board from Trio's newest
        /// determination (`doseIOB`), and only when that leaves at least the pump's bolus increment. Nil without a test or a recent
        /// reading, at or below the target, and with Count It when insulin on board covers the correction or hasn't been
        /// read recently (`noDoseReason` says which).
        var docsDose: Decimal? {
            test.flatMap { ISFTestEvaluator.docsDose(of: $0, doseInputs) }
        }

        /// The ISF and target the Dose step works the dose out with: those in force now, from the schedules Begin saved
        /// (`ISFTestEvaluator.doseSettings`), so an ISF that changed since Start is the one the dose uses, and nothing
        /// edited since Begin is. Nil without a test.
        var doseSettings: (isf: Decimal, target: Decimal)? {
            test.map { ISFTestEvaluator.doseSettings(of: $0, at: Date()) }
        }

        /// The pump's bolus increment: the pump can't give less, so a counted dose under it is none.
        private var bolusIncrement: Decimal {
            let manager: SettingsManager? = settingsManager
            return manager?.preferences.bolusIncrement ?? 0
        }

        /// Whether the Dose step takes insulin on board off the docs' correction: in a test that counts it.
        var dosesCountIOB: Bool {
            test?.iobHandling == .count
        }

        /// The docs' correction before insulin on board is taken off, for the formula card of a test that counts it.
        var docsCorrection: Decimal? {
            guard let settings = doseSettings, let glucose = doseGlucose else { return nil }
            return ISFTestEvaluator.dose(glucose: glucose, target: settings.target, isf: settings.isf)
        }

        /// Whether the correction follows "≈": rounded to 2 decimals, or worked out from values shown in mmol/L.
        var docsCorrectionIsApproximate: Bool {
            guard let settings = doseSettings, let glucose = doseGlucose,
                  let exact = ISFTestEvaluator.unroundedDose(glucose: glucose, target: settings.target, isf: settings.isf)
            else { return false }
            return ISFTestEvaluator.isApproximate(exact, fractionDigits: 2, units: glucoseUnits)
        }

        /// Why there is no `docsDose`, for the Dose step to say. Nil when there is one. Carbs on board give none: the docs
        /// test ISF "when fasting (no COB)". The runner reads the same rule to know whether the step shows a dose
        /// (`ISFTestEvaluator.doseStepOffer`). Without a test there are no settings to work it out with.
        var noDoseReason: ISFTestNoDose? {
            guard let test else { return .noSettings }
            return ISFTestEvaluator.noDoseReason(of: test, doseInputs)
        }

        /// Whether the docs' dose follows "≈": rounded to 2 decimals, or worked out from values shown in mmol/L.
        var docsDoseIsApproximate: Bool {
            guard let test, let settings = doseSettings, let glucose = doseGlucose,
                  let exact = ISFTestEvaluator.unroundedTestDose(
                      glucose: glucose,
                      target: settings.target,
                      isf: settings.isf,
                      handling: test.iobHandling,
                      iob: doseIOB,
                      increment: bolusIncrement
                  )
            else { return false }
            // Counted, the dose is the shown correction less the shown insulin on board unless the correction was rounded.
            return ISFTestEvaluator.isApproximate(exact, fractionDigits: 2, units: glucoseUnits)
                || (dosesCountIOB && docsCorrectionIsApproximate)
        }

        /// The time the bolus must come by, worded as the app's limit it is (R1), not a treatment rule.
        var doseDeadlineText: String? {
            guard let test else { return nil }
            let minutes = Int(Config.doseAllowance / 60)
            let time = test.doseDeadline.formatted(date: .omitted, time: .shortened)
            return String(localized: "The test needs your bolus within \(minutes) minutes of starting, by \(time).")
        }

        /// The Recommended Bolus Percentage as a fraction, e.g. 0.8.
        private var recommendedBolusFraction: Decimal {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.overrideFactor ?? 1
        }

        /// About what Trio's bolus calculator will suggest for the docs' dose.
        var trioSuggestion: Decimal? {
            docsDose.map { ISFTestEvaluator.suggestion(for: $0, percentage: recommendedBolusFraction) }
        }

        /// The Recommended Bolus Percentage as a whole percent, e.g. 80.
        var bolusPercent: Int {
            NSDecimalNumber(decimal: rounded(recommendedBolusFraction * 100, scale: 0, roundingMode: .plain)).intValue
        }

        /// What the Dose step's yellow note and its info sheet say about Trio's `suggestion` beside the formula's `dose`,
        /// by whether the Recommended Bolus Percentage makes it less than, the same as, or more than the dose. A suggestion
        /// less than the dose that would be too small for the test to judge while the dose isn't
        /// (`ISFTestEvaluator.suggestionTooSmall`, from the glucose and ISF the dose is worked out with) says to enter the
        /// dose, as one more than it does. Each amount stays on one line with its "U" (`SettingsTestFormat.keepTogether`),
        /// so a large text size doesn't leave "1.79" at the end of one line and "U." at the start of the next.
        func suggestionNote(suggestion: Decimal, dose: Decimal) -> (note: String, info: String) {
            let suggested = SettingsTestFormat.keepTogether(formatUnits(suggestion), unit: "U")
            let docs = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
            let percent = bolusPercent
            let perUnit = String(
                localized: "Tap Trio's suggestion or enter the formula's dose: the test judges your ISF per unit you actually give."
            )
            let comparison = ISFTestEvaluator.suggestionComparison(percent: percent)
            if comparison == .less, let glucose = doseGlucose, let isf = doseSettings?.isf,
               ISFTestEvaluator.suggestionTooSmall(
                   suggestion: suggestion,
                   dose: dose,
                   glucose: glucose,
                   isf: isf,
                   iob: currentIOB ?? 0
               )
            {
                return (
                    String(
                        localized: "Trio will suggest about \(suggested). That's \(percent)% of the formula's \(docs). Enter the formula's \(docs) instead of tapping Trio's suggestion."
                    ),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%). That's too small for this test to tell your ISF apart from CGM noise, so enter the formula's \(docs)."
                    )
                )
            }
            switch comparison {
            case .less:
                return (
                    String(
                        localized: "Trio will suggest about \(suggested). That's \(percent)% of the formula's \(docs). Either is fine: the result is worked out from what you give."
                    ),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%). SMBs normally give the rest, but they're off during the test."
                    ) + " " + perUnit
                )
            case .same:
                return (
                    String(localized: "Trio will suggest about the formula's \(docs)."),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%), so the two match."
                    ) + " " + perUnit
                )
            case .more:
                // More than the docs' dose can bring on a low the ISF doesn't explain, so the docs' dose is the one to give.
                return (
                    String(
                        localized: "Trio will suggest about \(suggested). That's \(percent)% of the formula's \(docs). Enter the formula's \(docs) instead of tapping Trio's suggestion."
                    ),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%), so its suggestion is more than the formula's dose."
                    ) + " " + String(localized: "Enter the formula's \(docs) instead of tapping Trio's suggestion.")
                )
            }
        }

        /// Whether the dose can be worked out now (`ISFTestEvaluator.canDose`): dosing, when the docs' formula gives one,
        /// the CGM's arrow is flat (or there is none for a recent reading, R6) and insulin on board is under the line for
        /// the dose shown; raising, once the tablets were taken, glucose has risen from them and then leveled off.
        var canDose: Bool {
            test.map { ISFTestEvaluator.canDose(of: $0, doseInputs) } ?? false
        }

        /// Whether the CGM shows glucose leveled off: a flat arrow, or none for a recent reading (R6).
        var glucoseIsLevel: Bool {
            ISFTestEvaluator.glucoseIsLevel(doseInputs)
        }

        /// Whether the tablets taken have acted: the mean of the newest 3 readings after them above the glucose they were
        /// counted from (`ISFTestEvaluator.tabletsActed`). False before they are taken.
        var tabletsActed: Bool {
            test.map { ISFTestEvaluator.tabletsActed(of: $0, doseInputs) } ?? false
        }

        /// Whether glucose rose from the tablets taken and then stopped rising (`ISFTestEvaluator.tabletsLeveledOff`).
        /// False before they are taken.
        var tabletsLeveledOff: Bool {
            test.map { ISFTestEvaluator.tabletsLeveledOff(of: $0, doseInputs) } ?? false
        }

        /// Whether the Dose step after tablets waits for glucose to stop rising again, as the bolus check would hold it
        /// (`ISFTestEvaluator.canDose`).
        var doseWaitsForTablets: Bool {
            guard let test, test.phase == .dosing, test.tabletsTakenAt != nil else { return false }
            return !tabletsLeveledOff
        }

        /// What the Raise step's leveling card says the readings mean for the dose, once there is a recent reading: carbs
        /// on board read as none, then glucose risen from the tablets, so a flat reading from before they acted can't
        /// unlock it, then stopped rising, then a level arrow. Nil while glucose has risen and still rises under a level
        /// arrow: the card's title says it waits for glucose to level off (`ISFTestEvaluator.levelingTitle`).
        var raiseStatus: String? {
            if canDose {
                return trendArrow == nil
                    ? String(localized: "Your CGM gives no arrow, so check that the readings have leveled off.")
                    : String(localized: "Your glucose has leveled off.")
            }
            // Carbs on board hold the dose on this path too, and unread they aren't known to be none.
            if currentCOB == nil {
                return String(localized: "Waiting for Trio to read carbs on board")
            }
            if !ISFTestEvaluator.carbsAllowDose(currentCOB) {
                return ISFTestEvaluator.noDoseSentence(.carbsOnBoard)
            }
            if !tabletsActed {
                return String(localized: "Waiting for your glucose to rise from the tablets.")
            }
            if !tabletsLeveledOff { return nil }
            return String(localized: "Work Out My Dose turns on once the arrow is flat.")
        }

        /// Why Work Out My Dose is off, in the words the Raise step shows for it: waiting for a recent reading, or what its
        /// leveling card says (`raiseStatus`, or its title when that has no line). Nil while it is on.
        var raiseHoldText: String? {
            guard !canDose else { return nil }
            if doseGlucose == nil { return WaitingRow.recentReading.text }
            return raiseStatus ?? ISFTestEvaluator.levelingTitle(phase: .raising, tabletsActed: tabletsActed)
        }

        /// The Dose step's line while insulin on board is over the line for the dose shown: how much there is against the
        /// line, or that Trio hasn't read it. Nil without a dose.
        var iobWaitText: String? {
            guard let dose = docsDose else { return nil }
            let doseText = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
            guard let iob = currentIOB, let line = doseIOBLine else {
                return String(localized: "Waiting for Trio's insulin on board.")
            }
            let iobText = SettingsTestFormat.keepTogether(formatSignedUnits(iob), unit: "U")
            return iob < 0
                ? String(
                    localized: "Your insulin on board is \(iobText), more than \(lineText(line)) from zero: \(stepPercent)% of this dose of \(doseText), the smallest ISF change in Trio docs."
                )
                : String(
                    localized: "Your insulin on board is \(iobText), over \(lineText(line)): \(stepPercent)% of this dose of \(doseText), the smallest ISF change in Trio docs."
                )
        }

        /// Why Open Treatments is off, in the words the Dose step shows for it: why there is no dose, or what it waits for;
        /// the leveling card's line while the arrow moves, or its title while glucose still rises after the tablets; or the
        /// insulin on board card's line. Nil while it is on.
        var doseHoldText: String? {
            guard !canDose else { return nil }
            if let reason = noDoseReason {
                switch reason {
                case .noRecentReading: return WaitingRow.recentReading.text
                case .carbsUnread: return String(localized: "Waiting for Trio to read carbs on board")
                case .iobUnread: return String(localized: "Waiting for Trio's insulin on board")
                case .atOrBelowTarget,
                     .carbsOnBoard,
                     .iobCoversDose,
                     .isfChanges,
                     .isfChangesUntilDeadline,
                     .noSettings: return ISFTestEvaluator.noDoseSentence(reason)
                }
            }
            if !glucoseIsLevel { return String(localized: "Open Treatments turns on once the arrow is flat.") }
            if doseWaitsForTablets { return ISFTestEvaluator.levelingTitle(phase: .dosing, tabletsActed: true) }
            return doseIOBAllows ? nil : iobWaitText
        }

        /// The line insulin on board must be under before the dose shown, in a test that doesn't count it: the docs'
        /// smallest ISF change of that dose (`ISFTestEvaluator.doseIOBLine`), not of the one Begin expected. Nil without a
        /// dose, and in a test that counts insulin on board.
        var doseIOBLine: Decimal? {
            ISFTestEvaluator.doseIOBLine(dose: docsDose, handling: test?.iobHandling)
        }

        /// Whether insulin on board lets the dose shown go ahead (`ISFTestEvaluator.doseIOBAllows`).
        var doseIOBAllows: Bool {
            ISFTestEvaluator.doseIOBAllows(of: test, doseInputs)
        }

        /// The 4 hours from now, as the parts of the day they cover with their ISFs, from the schedule Begin saved, as the
        /// Check screen's ISF-change row reads them (`ISFTestEvaluator.isfChangeReading`). Nil without a test or entries.
        var doseISFChangeReading: String? {
            guard let entries = test?.coveredEntries else { return nil }
            let spans = ISFTestEvaluator.coveredSpans(entries, from: Date(), for: Config.docsWait)
            return spans.isEmpty ? nil : ISFTestEvaluator.isfChangeReading(spans, units: glucoseUnits)
        }

        // MARK: - Waiting

        /// Time since the bolus.
        var elapsed: TimeInterval {
            guard let bolusAt = test?.bolusAt else { return 0 }
            return max(0, Date().timeIntervalSince(bolusAt))
        }

        /// Time left of the docs' 4 hours.
        var remaining: TimeInterval {
            guard let plannedEnd = test?.plannedEnd else { return Config.docsWait }
            return max(0, plannedEnd.timeIntervalSinceNow)
        }

        var progress: Double {
            min(1, elapsed / Config.docsWait)
        }

        /// Readings since the bolus, oldest first. One at the same moment as the saved bolus counts as at it.
        var runningReadings: [BasalTestReading] {
            guard let bolusAt = test?.bolusAt else { return [] }
            return ISFTestEvaluator.readings(recentReadings, since: bolusAt).sorted { $0.date < $1.date }
        }

        // MARK: - Result

        /// The finished test's result, worked out again from what it saved, with the drop per unit and share behind it.
        /// Nil when it doesn't give the verdict the headline shows (`ISFTestEvaluator.matchingEvaluation`).
        var evaluation: ISFTestEvaluator.Evaluation? {
            test.flatMap { ISFTestEvaluator.matchingEvaluation(of: $0) }
        }

        /// The band the result chart shades, where glucose would end if the ISF were less than a docs step either way.
        /// Nil for a result not judged on the drop, and when no whole reading lies inside it.
        var resultBand: ClosedRange<Int>? {
            test.flatMap { ISFTestEvaluator.resultBand(of: $0) }
        }

        /// The last part of the 4 hours, where the chart shades the band.
        var resultBandTimes: ClosedRange<Date>? {
            test.flatMap { ISFTestEvaluator.resultBandTimes(of: $0) }
        }

        /// Where glucose would end if the ISF were right, in mg/dL, when that isn't at the target: the dose given wasn't
        /// the docs' dose. Nil otherwise.
        var expectedEndAwayFromTarget: Decimal? {
            test.flatMap { ISFTestEvaluator.expectedEndAwayFromTarget(of: $0) }
        }

        /// Why the finished test says nothing about the ISF. Nil when it does.
        var noVerdict: ISFTestNoVerdict? {
            test.flatMap { ISFTestEvaluator.noVerdict(for: $0) }
        }

        /// The tablets taken before the dose, nil when none were.
        var resultTablets: ISFTestTablets? {
            ISFTestEvaluator.takenTablets(carbs: test?.tabletCarbs, brand: test?.tabletBrand)
        }

        /// What the Result offers for a verdict that says to change the ISF (`ISFTestEvaluator.resultAction`): Open
        /// Insulin Sensitivities, or the docs' line for Logarithmic Dynamic ISF while it is on. Basal Testing turns
        /// Dynamic ISF off only for the test, so the user's own setting is read. Nil for any other result.
        var resultAction: ISFTestResultAction? {
            guard let outcome = test?.outcome else { return nil }
            let manager: SettingsManager? = settingsManager
            let preferences = manager?.preferences ?? Preferences()
            return ISFTestEvaluator.resultAction(
                outcome: outcome,
                logarithmicDynamicISF: preferences.useNewFormula && !preferences.sigmoid
            )
        }

        // MARK: - Subscription

        override func subscribe() {
            if let runner = runner ?? testService.isfRunner {
                follow(runner)
            } else {
                warning(.settings, "ISFTest: the settings test service has no ISF runner, so the screen can't run a test")
            }
            if let raw = test?.tabletBrand, let brand = GlucoseTabletBrand(rawValue: raw) {
                selectedBrand = brand
            }

            glucoseStorage.updatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            CoreDataStack.shared.entityChangePublisher
                .receive(on: DispatchQueue.main)
                .filteredByEntityName("OrefDetermination")
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            // A bolus is in the pump history before the next loop, so the Dose step moves on as soon as Trio sees it.
            CoreDataStack.shared.entityChangePublisher
                .receive(on: DispatchQueue.main)
                .filteredByEntityName("PumpEventStored")
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            // Right away, so the first frame doesn't show "No other test running" as passed, or no basal test.
            showSession(testService.activeSession, lastEnd: testService.lastEnd())
            basalGate = readBasalGate()
            testService.sessionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in self?.showSession(session, lastEnd: self?.testService.lastEnd()) }
                .store(in: &dataSubscriptions)

            Task { await refresh() }
        }

        /// Shows the runner's state now, so the first frame is the test's step, and each change it publishes, on the main
        /// queue.
        func follow(_ runner: ISFTestRunning) {
            self.runner = runner
            apply(runner.state)
            runner.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in self?.apply(state) }
                .store(in: &dataSubscriptions)
        }

        /// Shows the service's session: the one running, and the one it last ended on its own (`lastEnd`), kept before it
        /// sent its end, so a step whose session ended shows as ending (`isEnding`).
        func showSession(_ session: SettingsTestSession?, lastEnd: SettingsTestEnd?) {
            activeSessionKind = session?.kind
            serviceSession = (activeID: session?.id, lastEndID: lastEnd?.sessionID)
        }

        /// Whether the test is ending, so its step takes none of its actions (`SettingsTestModeRule.isEnding`): its ending
        /// is saved, or its session no longer runs while its runner's finish is to come.
        var isEnding: Bool {
            guard let test else { return false }
            return SettingsTestModeRule.isEnding(
                hasPendingEnd: test.pendingEnd != nil,
                isRunning: test.phase != .finished,
                testSessionID: test.sessionID,
                session: serviceSession,
                mode: currentMode,
                previousMode: test.previousMode
            )
        }

        /// Shows what the runner publishes: the test, settling's last check, and insulin on board for a counted dose. The
        /// only place these change.
        func apply(_ runnerState: ISFTestRunnerState) {
            test = runnerState.test
            settling = runnerState.settling?.decision
            settlingBoluses = runnerState.settling?.boluses ?? []
            settleReadings = runnerState.settling?.readingsAfterLoop
            settleTempBasalRunning = runnerState.settling?.tempBasalRunning ?? false
            settleIOB = runnerState.settling?.iob
            doseIOB = runnerState.doseIOB
        }

        /// What `refresh` reads for the Check, Raise and Dose steps, shown in one step on the main actor (`show`).
        struct ScreenData {
            /// Newest first.
            var readings: [BasalTestReading]
            var iob: Decimal?
            var cob: Decimal?
            var hasActiveAdjustment: Bool
            var hasPumpSetTempBasal: Bool
            var pumpDelivery: ISFTestPumpDelivery?
            var hasDevices: Bool
            var trendDirection: BloodGlucose.Direction?
        }

        /// Shows what `refresh` read.
        func show(_ data: ScreenData) {
            recentReadings = data.readings
            readIOB = data.iob
            currentCOB = data.cob
            hasActiveAdjustment = data.hasActiveAdjustment
            hasPumpSetTempBasal = data.hasPumpSetTempBasal
            pumpDelivery = data.pumpDelivery
            hasDevices = data.hasDevices
            trendDirection = data.trendDirection
        }

        /// Pulls fresh data for the screen, then has the runner check a running test: for its bolus, whether it should
        /// stop, and insulin on board for a counted dose. Refreshes overlap (each new reading, determination and pump event
        /// starts one) and can finish out of order, so one that finishes after a newer one has shown its reads shows
        /// nothing, neither its reads nor its error: an older snapshot never replaces a newer one.
        func refresh() async {
            let number = await MainActor.run { () -> Int in
                refreshesBegun += 1
                return refreshesBegun
            }
            let reads = self.reads
            let now = Date()
            let schedule = reads.isfEntries()
            let isf = reads.isf(at: now)
            let target = reads.target(at: now)
            let gate = readBasalGate()
            await MainActor.run {
                isfSchedule = schedule
                isfNow = isf
                targetNow = target
                basalGate = gate
            }
            do {
                let readings = try await reads.fetchRecentGlucose(minutes: Self.recentReadingsMinutes)
                let iob = reads.currentIOB()
                // From a determination at most 12 minutes old; none, or a read that failed, is unread, not none.
                let cob = (try? await reads.currentCOB()) ?? nil
                let adjustment = try await reads.hasActiveAdjustment()
                let pumpTempBasal = reads.hasPumpSetTempBasal()
                let delivery = reads.pumpDelivery()
                let devices = reads.hasCgmAndPump()
                // The CGM's arrow on the newest of these readings, from the same row: a separate read could find a
                // reading saved since, with an arrow newer than the readings the dose comes from.
                let direction = readings.first?.direction
                let data = ScreenData(
                    readings: readings,
                    iob: iob,
                    cob: cob,
                    hasActiveAdjustment: adjustment,
                    hasPumpSetTempBasal: pumpTempBasal,
                    pumpDelivery: delivery,
                    hasDevices: devices,
                    trendDirection: direction
                )
                await MainActor.run {
                    guard number > newestRefreshShown else { return }
                    newestRefreshShown = number
                    show(data)
                }
            } catch {
                await MainActor.run {
                    guard number > newestRefreshShown else { return }
                    errorMessage = "Couldn't read your data: \(error.localizedDescription)"
                }
            }
            await runner?.check()
        }

        /// The newest basal test against the basal schedule now.
        private func readBasalGate() -> SettingsTestSchedule.BasalGate {
            SettingsTestSchedule.basalGate(history: testService.history(for: .basal), current: reads.basalEntries())
        }

        // MARK: - Start

        private var noRecentGlucoseMessage: String {
            String(localized: "Trio has no recent glucose reading. Wait for your CGM's next reading, then try again.")
        }

        func requestStart() {
            guard readyToStart else { return }
            // The dose needs a glucose to start from, and no row blocks on it.
            guard doseGlucose != nil else {
                errorMessage = noRecentGlucoseMessage
                return
            }
            guard let isf = isfNow, isf > 0, targetNow != nil else {
                errorMessage = String(localized: "Trio couldn't read your ISF and glucose target. Check them, then try again.")
                return
            }
            showStartConfirmation = true
        }

        /// Begin: the runner saves the test, starts its session and switches to Basal Testing. Only when every check
        /// passes, Basal Testing being off among them, so the runner never records it as the usual mode, and with a
        /// glucose to start from: none is made up.
        @MainActor func confirmStart() {
            showStartConfirmation = false
            guard readyToStart else { return }
            // The reading may have grown too old while the confirmation was up.
            guard let glucose = doseGlucose else {
                errorMessage = noRecentGlucoseMessage
                return
            }
            let begin = ISFTestBegin(glucose: glucose, iob: currentIOB, iobChoice: iobChoice)
            // Begin reads the carb entries there now before it switches the mode.
            Task { @MainActor in
                if let error = await runner?.begin(begin) {
                    errorMessage = error.message
                }
            }
        }

        // MARK: - Settle

        /// After the settling allowance, with insulin on board still over the line: count it and go on.
        @MainActor func countAndGoOn() {
            guard !isEnding, case .timeUp = settling else { return }
            runner?.countAndGoOn()
        }

        /// Whether the Settle step shows insulin on board: in a test that waits for it, and in one that had no choice once
        /// it went over the line.
        var settleShowsIOB: Bool {
            guard let test, test.iobLine != nil else { return false }
            if test.iobHandling == .count { return false }
            if test.iobHandling == .wait { return true }
            return ISFTestEvaluator.waitsForIOB(iob: currentIOB, line: test.iobLine, handling: test.iobHandling)
        }

        /// Settling's one line: what it waits for, or, once the time is up with no loop in Basal Testing, that it can't
        /// start.
        var settleLine: String {
            switch settling {
            case .noLoop:
                return String(localized: "SMBs are off, but Trio hasn't looped in Basal Testing since you began.")
            case .tooFewReadings:
                return String(localized: "SMBs are off, but your CGM hasn't had enough readings since Trio's first loop.")
            case .tempBasalRunning:
                return String(localized: "SMBs are off, but a temp basal is still running on your pump.")
            case nil,
                 .settled,
                 .timeUp,
                 .waiting:
                break
            }
            let readings = Config.settleReadings
            guard settleShowsIOB, let line = test?.iobLine else {
                return String(
                    localized: "SMBs are off. The test starts after Trio's first loop in Basal Testing and \(readings) CGM readings since."
                )
            }
            let lineText = lineText(line)
            return (currentIOB ?? 0) < 0
                ? String(
                    localized: "SMBs are off. The test starts after Trio's first loop in Basal Testing and \(readings) CGM readings since, once your insulin on board is within \(lineText) of zero."
                )
                : String(
                    localized: "SMBs are off. The test starts after Trio's first loop in Basal Testing and \(readings) CGM readings since, once your insulin on board is under \(lineText)."
                )
        }

        /// When Trio first looped in Basal Testing, nil until it has.
        var settleLoopedAt: Date? {
            switch settling {
            case let .timeUp(loopedAt): return loopedAt
            case let .tooFewReadings(loopedAt): return loopedAt
            case let .tempBasalRunning(loopedAt): return loopedAt
            case let .waiting(loopedAt, _): return loopedAt
            case nil,
                 .noLoop,
                 .settled: return nil
            }
        }

        /// The Settle step's readings row: "2 of 3" CGM readings since Trio's first loop in Basal Testing, or done once
        /// there are enough. Nil before that loop.
        var settleReadingsText: String? {
            guard settleLoopedAt != nil, let count = settleReadings else { return nil }
            let needed = Config.settleReadings
            return count >= needed ? String(localized: "Done") : String(localized: "\(count) of \(needed)")
        }

        /// Whether settling still waits for insulin on board to come under the line, from the insulin on board now.
        var settleWaitsForIOB: Bool {
            guard let test, test.phase == .settling else { return false }
            return ISFTestEvaluator.waitsForIOB(iob: currentIOB, line: test.iobLine, handling: test.iobHandling)
        }

        /// Once the settling allowance is up with no loop in Basal Testing, too few CGM readings since it, or a temp basal
        /// still running: counting insulin on board can't help, so the step offers only Cancel.
        /// The runner ends the test with the same sentence (`ISFTestEvaluator.deadEndSentence`).
        var settleNoLoopMessage: String? {
            settling.flatMap(ISFTestEvaluator.deadEndSentence(settling:))
        }

        /// The question once the settling allowance is up with insulin on board still over the line, or still unread.
        /// Nil until then.
        var settleTimeUpQuestion: String? {
            guard case .timeUp = settling, let line = test?.iobLine else { return nil }
            guard let currentIOB else {
                return String(localized: "Trio still hasn't read your insulin on board. Count it and go on, or cancel?")
            }
            let iob = SettingsTestFormat.keepTogether(formatSignedUnits(currentIOB), unit: "U")
            return currentIOB < 0
                ? String(
                    localized: "Your insulin on board is still \(iob), more than \(lineText(line)) from zero. Count it and go on, or cancel?"
                )
                :
                String(
                    localized: "Your insulin on board is still \(iob), over \(lineText(line)). Count it and go on, or cancel?"
                )
        }

        // MARK: - Raise and dose

        /// The user took the tablets the Raise step counted. They are kept for the record, not logged as carbs, and the
        /// step then waits for glucose to level off. Without a count there is nothing to have taken, so it says why; once
        /// they are marked taken, another tap does nothing (the runner's).
        @MainActor func tabletsTaken() {
            guard !isEnding else { return }
            let count = tabletCount
            guard count > 0 else {
                errorMessage = noTabletsReason == .noRecentReading ? noRecentGlucoseMessage : noTabletsMessage
                return
            }
            // What glucose has to rise above before the dose, so a reading from before they acted can't unlock it.
            runner?.tabletsTaken(ISFTestTabletsTaken(brand: selectedBrand, count: count, glucose: doseGlucose))
        }

        /// From the Raise step to the Dose step, once glucose has leveled off after the tablets, with what the step read,
        /// which the runner judges again. A tap the step drew before its gate shut says why (`raiseHoldText`).
        @MainActor func workOutDose() {
            guard !isEnding else { return }
            guard canDose else {
                errorMessage = raiseHoldText
                return
            }
            runner?.workOutDose(doseInputs)
        }

        /// From the Raise step to the Dose step without tablets; the runner does nothing once they are taken.
        @MainActor func skipTablets() {
            guard !isEnding else { return }
            runner?.moveToDose()
        }

        /// Back from the Dose step to the Raise step, only when glucose is at or below the target, so the docs' formula
        /// gives no dose, and the target is below the docs' 150 for tablets to aim past (`canRaise`). Tablets already
        /// taken stay in the record.
        @MainActor func raiseFirst() {
            guard !isEnding, noDoseReason == .atOrBelowTarget, canRaise else { return }
            runner?.raiseFirst()
        }

        /// Trio's own Treatments screen gives the bolus, so its checks all apply. A tap the step drew before its gate shut
        /// (a reading that aged since, say) says why (`doseHoldText`).
        @MainActor func openTreatments() {
            guard !isEnding else { return }
            guard canDose else {
                errorMessage = doseHoldText
                return
            }
            sendToTreatments()
        }

        /// Opens Treatments. A screen opened from a notice comes back when Treatments closes (`treatmentsOpened`).
        @MainActor func sendToTreatments() {
            if opener.wasOpenedFromNotice(.isf) {
                opener.treatmentsOpened(from: .isf)
            }
            router.mainModalScreen.send(.treatmentView)
        }

        // MARK: - Running

        /// Has the runner check the test now: the steps' timers, and the Wait step's.
        func checkRunningTest() async {
            await runner?.check()
        }

        /// End Test: ending early gives no result.
        func endEarly() async {
            guard await MainActor.run(body: { !isEnding }) else { return }
            await runner?.endEarly()
        }

        /// Cancel Test, before the bolus: the usual mode comes back and nothing is kept. The next test's Check starts on
        /// the docs' way.
        @MainActor func discard() {
            guard !isEnding else { return }
            runner?.discard()
            iobChoice = .wait
            checkPage = .checks
            Task { await refresh() }
        }

        /// Done: clears a finished result so the user can start over, on the docs' way.
        @MainActor func acknowledgeResult() {
            runner?.acknowledgeResult()
            iobChoice = .wait
            checkPage = .checks
            Task { await refresh() }
        }

        /// Whether Basal Testing is still on with no test running it, so the Result says so instead of the usual dosing
        /// coming back (`SettingsTestModeRule.basalTestingLeftOn`).
        var basalTestingLeftOn: Bool {
            SettingsTestModeRule.basalTestingLeftOn(mode: currentMode, activeSessionID: testService.activeSession?.id)
        }
    }
}
