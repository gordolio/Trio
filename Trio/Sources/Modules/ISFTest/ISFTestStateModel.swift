import Combine
import CoreData
import Foundation
import Observation
import SwiftUI
import UserNotifications

extension ISFTest {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!

        /// How far before the bolus to read glucose for the start glucose: the newest 3 readings at or before it are
        /// all it uses.
        private static let startReadingsLookback: TimeInterval = 3600
        /// How far back the screen reads glucose: the longest a test runs, 90 minutes for the bolus and 4 hours after
        /// it, with time to spare.
        private static let recentReadingsMinutes = 6 * 60
        private static let finishedNotificationID = "Trio.isfTestFinished"

        // MARK: - State

        /// The test in progress or just finished. `nil` while the user is still getting ready.
        var test: ISFTestState?

        /// Newest first.
        private(set) var recentReadings: [BasalTestReading] = []
        /// Nil while Trio hasn't worked insulin on board out.
        private(set) var currentIOB: Decimal?
        /// Insulin on board for a counted dose, from Trio's newest determination of the last 12 minutes
        /// (`ISFTestEvaluator.recentIOB`). Nil when there is none, or in a test that doesn't count it.
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
        @ObservationIgnored private var isFinishing = false

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
            return Date().timeIntervalSince(latest) > 15 * 60
        }

        /// The glucose the dose and the tablets are worked out from: the mean of the last 3 readings, nil when the
        /// newest is older than `BasalTest.Config.endReadingMaxAge`.
        var doseGlucose: Int? {
            BasalTestEvaluator.endGlucose(from: Array(recentReadings.prefix(3)), endingAt: Date())
        }

        /// The CGM's own arrow for a recent reading. Nil when it gave none.
        private var shownDirection: BloodGlucose.Direction? {
            readingIsStale ? nil : trendDirection
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
            var checks = [devicesCheck, pumpSuspendedCheck, adjustmentsCheck, pumpTempBasalCheck, modeCheck, otherTestCheck]
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

        /// Whether the 4 hours from now cover more than one ISF value (R3). It only informs: the dose and the result use
        /// the ISF in force at Start.
        var crossesISFChange: Bool {
            ISFTestEvaluator.crossesISFChange(isfSchedule, from: Date(), for: Config.docsWait)
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
                detail: modeAvailable
                    ? String(localized: "\(currentMode.displayName) now. Trio returns to it after.")
                    : String(localized: "Switch to your usual dosing mode first, so Trio can return you to it"),
                state: modeAvailable ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "Basal Testing is off"),
                    body: String(
                        localized: "Trio switches itself to Basal Testing for the test and puts your usual dosing mode back afterwards, so it has to start from another mode."
                    )
                )
            )
        }

        private var otherTestCheck: Check {
            Check(
                id: "otherTest",
                title: String(localized: "No other test running"),
                detail: activeSessionKind.map { String(localized: "The \($0.title) test is still running. Finish it first.") },
                state: activeSessionKind == nil ? .passed : .failed,
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
                        localized: "The docs' dose is your glucose minus your target, divided by your ISF, so the test needs glucose above your target, and tablets can't raise it there. \(tabletAimText)"
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
                localized: "The test's tablets aim for around \(aim), from the docs' \"around 150 mg/dL or 8.3 mmol/L\". At a target of \(aim) or more, the test has no higher number to aim for."
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

        /// Warns once insulin on board is over the test's line, where the card under it asks how to handle it. Before
        /// Trio has worked it out, it says so and doesn't hold up Begin; settling then waits for it.
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
                    localized: "Insulin still working from an earlier dose or SMB adds to the drop the test measures, and negative insulin on board, basal Trio held back, takes from it. More than \(stepPercent)% of the test's dose, the docs' smallest ISF change, can sway the result, so you choose whether the test waits for it or counts it. More than the whole dose holds up the start."
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

        /// Shown only when the 4 hours from now cover more than one ISF value.
        private var isfChangeCheck: Check? {
            guard crossesISFChange else { return nil }
            let entries = plannedEntries
            let spans = entries.map { "\(SettingsTestSchedule.spanText(of: $0, inSentence: true)) \(formatISF($0.value))" }
                .joined(separator: ", ")
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
            guard let test, let settings = doseSettings, let glucose = doseGlucose else { return nil }
            return ISFTestEvaluator.testDose(
                glucose: glucose,
                target: settings.target,
                isf: settings.isf,
                handling: test.iobHandling,
                iob: doseIOB,
                increment: bolusIncrement,
                carbsOnBoard: currentCOB
            )
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
        /// test ISF "when fasting (no COB)".
        var noDoseReason: ISFTestNoDose? {
            ISFTestEvaluator.noDoseReason(
                glucose: doseGlucose,
                target: doseSettings?.target,
                isf: doseSettings?.isf,
                handling: test?.iobHandling,
                iob: doseIOB,
                increment: bolusIncrement,
                carbsOnBoard: currentCOB
            )
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

        /// Whether the dose can be worked out now (`ISFTestEvaluator.canDose`): dosing, when the docs' formula gives one,
        /// the CGM's arrow is flat (or there is none for a recent reading, R6) and insulin on board is under the line for
        /// the dose shown; raising, once the tablets were taken, glucose has risen from them and then leveled off.
        var canDose: Bool {
            guard let test else { return false }
            return ISFTestEvaluator.canDose(
                phase: test.phase,
                tabletsTaken: test.tabletsTakenAt != nil,
                tabletsActed: tabletsActed,
                direction: shownDirection,
                hasRecentReading: doseGlucose != nil,
                dose: docsDose,
                iobAllowsDose: doseIOBAllows,
                carbsOnBoard: currentCOB
            )
        }

        /// Whether the CGM shows glucose leveled off: a flat arrow, or none for a recent reading (R6).
        var glucoseIsLevel: Bool {
            ISFTestEvaluator.isLevel(direction: shownDirection, hasRecentReading: doseGlucose != nil)
        }

        /// Whether the tablets taken have acted: a reading after them above the glucose they were counted from, and a
        /// reading after that one (`ISFTestEvaluator.tabletsActed`). False before they are taken.
        var tabletsActed: Bool {
            guard let test, let takenAt = test.tabletsTakenAt else { return false }
            return ISFTestEvaluator.tabletsActed(recentReadings, tabletsTakenAt: takenAt, glucoseAtTablets: test.tabletsGlucose)
        }

        /// The line insulin on board must be under before the dose shown, in a test that doesn't count it: the docs'
        /// smallest ISF change of that dose (`ISFTestEvaluator.doseIOBLine`), not of the one Begin expected. Nil without a
        /// dose, and in a test that counts insulin on board.
        var doseIOBLine: Decimal? {
            ISFTestEvaluator.doseIOBLine(dose: docsDose, handling: test?.iobHandling)
        }

        /// Whether insulin on board lets the dose shown go ahead (`ISFTestEvaluator.iobAllowsDose`).
        var doseIOBAllows: Bool {
            ISFTestEvaluator.iobAllowsDose(iob: currentIOB, dose: docsDose, handling: test?.iobHandling)
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

        // MARK: - Subscription

        override func subscribe() {
            test = provider.storage.retrieve(Config.statePath, as: ISFTestState.self)
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
            activeSessionKind = testService.activeSession?.kind
            basalGate = readBasalGate()
            testService.sessionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in self?.activeSessionKind = session?.kind }
                .store(in: &dataSubscriptions)

            Task { await refresh() }
        }

        /// Pulls fresh data, then checks whether a running test has its bolus or should stop.
        func refresh() async {
            let now = Date()
            let schedule = provider.isfEntries()
            let isf = provider.isf(at: now)
            let target = provider.target(at: now)
            let gate = readBasalGate()
            await MainActor.run {
                isfSchedule = schedule
                isfNow = isf
                targetNow = target
                basalGate = gate
            }
            do {
                let shared = provider.shared
                let readings = try await shared.fetchRecentGlucose(minutes: Self.recentReadingsMinutes)
                let iob = provider.currentIOB()
                // From a determination at most 12 minutes old; none, or a read that failed, is unread, not none.
                let cob = (try? await provider.currentCOB()) ?? nil
                let adjustment = try await shared.hasActiveAdjustment()
                let pumpTempBasal = shared.hasPumpSetTempBasal()
                let delivery = provider.pumpDelivery()
                let devices = shared.hasCgmAndPump()
                let direction = try await shared.fetchNewestDirection()
                await MainActor.run {
                    recentReadings = readings
                    currentIOB = iob
                    currentCOB = cob
                    hasActiveAdjustment = adjustment
                    hasPumpSetTempBasal = pumpTempBasal
                    pumpDelivery = delivery
                    hasDevices = devices
                    trendDirection = direction
                }
            } catch {
                await MainActor.run { errorMessage = "Couldn't read your data: \(error.localizedDescription)" }
            }
            // Before the bolus, the running check reads insulin on board for a counted dose (`refreshDoseIOB`).
            await checkRunningTest()
        }

        /// Reads insulin on board for a counted dose, before the bolus of a test that counts it, from Trio's newest
        /// determination of the last 12 minutes. Cleared otherwise, and when they can't be read.
        private func refreshDoseIOB() async {
            guard let test, test.iobHandling == .count, test.phase == .raising || test.phase == .dosing else {
                await MainActor.run { doseIOB = nil }
                return
            }
            let now = Date()
            let iob: Decimal?
            do {
                let determinations = try await provider.fetchDeterminations(
                    from: now.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - Config.savedDateTolerance),
                    to: now.addingTimeInterval(Config.savedDateTolerance)
                )
                iob = ISFTestEvaluator.recentIOB(determinations, now: now)
            } catch {
                warning(.settings, "ISFTest: couldn't read insulin on board for the dose", error: error)
                iob = nil
            }
            await MainActor.run { doseIOB = iob }
        }

        /// The newest basal test against the basal schedule now.
        private func readBasalGate() -> SettingsTestSchedule.BasalGate {
            SettingsTestSchedule.basalGate(history: testService.history(for: .basal), current: provider.basalEntries())
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

        func confirmStart() {
            showStartConfirmation = false
            guard readyToStart else { return }
            // The reading may have grown too old while the confirmation was up.
            guard let glucose = doseGlucose else {
                errorMessage = noRecentGlucoseMessage
                return
            }

            let now = Date()
            // What the dose and the result use, kept so neither depends on what the settings say by then.
            guard let isf = provider.isf(at: now), isf > 0, let target = provider.target(at: now) else {
                errorMessage = String(localized: "Trio couldn't read your ISF and glucose target. Check them, then try again.")
                return
            }
            let previous = currentMode
            var state = ISFTestState(
                phase: .settling,
                startedAt: now,
                previousMode: previous,
                isf: isf,
                target: target,
                carbRatio: provider.carbRatio(at: now)
            )
            // What insulin on board is measured against, fixed for the test, from the same glucose and settings.
            let path = ISFTestEvaluator.startPath(glucose: glucose, target: target)
            let expected = ISFTestEvaluator.expectedDose(startPath: path, glucose: glucose, target: target, isf: isf)
            state.expectedDose = expected
            state.iobLine = expected.map { ISFTestEvaluator.iobLine(expectedDose: $0) }
            state.iobHandling = ISFTestEvaluator.iobHandling(
                for: ISFTestEvaluator.iobDecision(iob: currentIOB, expectedDose: expected),
                chosen: iobChoice
            )
            state.plannedPhase = ISFTestEvaluator.startPhase(glucose: glucose, target: target)
            // The schedule as it is at Begin, over every hour settling, a bolus in the time allowed and its 4 hours could
            // reach, so an ISF edited before the bolus is found doesn't become what the test ran on.
            state.coveredEntries = ISFTestEvaluator.coveredAtBegin(provider.isfEntries(), startedAt: now)
            // The target schedule over the same hours, so the dose and the result use the target in force at the time.
            state.targetEntries = ISFTestEvaluator.coveredAtBegin(provider.targetEntries(), startedAt: now)
            // The docs' dose is rounded up to it before a low's bolus is held against it.
            state.bolusIncrement = bolusIncrement

            // Saved first, so a crash from here on leaves a test this screen can finish: one that never reached Basal
            // Testing ends as interrupted.
            provider.storage.save(state, as: Config.statePath)
            // Register the way back before changing anything, so an interruption can't leave the user in Basal Testing
            // with nobody watching it.
            guard let session = testService.begin(
                kind: .isf,
                expiresIn: Config.settleAllowance + Config.doseAllowance + Config.docsWait + Config.expiryGrace,
                restoring: [.dosingMode(testMode: .basalTesting, previous: previous)],
                settles: true
            ) else {
                provider.storage.remove(Config.statePath)
                errorMessage = String(localized: "Another settings test is running. Finish it first.")
                return
            }
            // Saved again with its session, before the mode changes, so the service's record of ending it can be matched
            // to this test.
            state.sessionID = session.id
            provider.storage.save(state, as: Config.statePath)
            settingsManager.settings.dosingMode = .basalTesting
            settling = nil
            settlingBoluses = []
            settleReadings = nil
            test = state
        }

        // MARK: - Settle

        /// After the settling allowance, with insulin on board still over the line: count it and go on.
        func countAndGoOn() {
            guard var current = test, current.phase == .settling, case .timeUp = settling else { return }
            current.iobHandling = .count
            save(current)
            Task { await checkRunningTest() }
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
        var settleNoLoopMessage: String? {
            switch settling {
            case .noLoop:
                return String(
                    localized: "Trio hasn't looped in Basal Testing yet, so the test can't start. Check your CGM and pump, then begin again."
                )
            case .tooFewReadings:
                return String(
                    localized: "Trio hasn't had enough CGM readings since you began to start the test. Check your CGM, then begin again."
                )
            case .tempBasalRunning:
                return String(
                    localized: "A temp basal is still running on your pump, so the test can't start. Cancel it on the pump, then begin again."
                )
            case nil,
                 .settled,
                 .timeUp,
                 .waiting:
                return nil
            }
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
        /// they are marked taken, another tap does nothing.
        func tabletsTaken() {
            guard var current = test, current.phase == .raising, current.tabletsTakenAt == nil else { return }
            let count = tabletCount
            guard count > 0 else {
                errorMessage = noTabletsReason == .noRecentReading ? noRecentGlucoseMessage : noTabletsMessage
                return
            }
            current.tabletBrand = selectedBrand.rawValue
            // Added to tablets taken before going back from the Dose step, so the record holds all of them.
            current.tabletCarbs = (current.tabletCarbs ?? 0) + Decimal(count) * selectedBrand.carbsPerTablet
            current.tabletsTakenAt = Date()
            // What glucose has to rise above before the dose, so a reading from before they acted can't unlock it.
            current.tabletsGlucose = doseGlucose
            save(current)
        }

        /// From the Raise step to the Dose step, once glucose has leveled off after the tablets.
        func workOutDose() {
            guard var current = test, current.phase == .raising, canDose else { return }
            current.phase = .dosing
            save(current)
        }

        /// From the Raise step to the Dose step without tablets.
        func skipTablets() {
            guard var current = test, current.phase == .raising else { return }
            current.phase = .dosing
            save(current)
        }

        /// Back from the Dose step to the Raise step, only when glucose is at or below the target, so the docs' formula
        /// gives no dose, and the target is below the docs' 150 for tablets to aim past (`canRaise`). Tablets already
        /// taken stay in the record.
        func raiseFirst() {
            guard var current = test, current.phase == .dosing, noDoseReason == .atOrBelowTarget, canRaise else { return }
            current.phase = .raising
            current.tabletsTakenAt = nil
            current.tabletsGlucose = nil
            save(current)
        }

        /// Trio's own Treatments screen gives the bolus, so its checks all apply.
        func openTreatments() {
            guard canDose else { return }
            router.mainModalScreen.send(.treatmentView)
        }

        private func save(_ state: ISFTestState) {
            provider.storage.save(state, as: Config.statePath)
            test = state
        }

        // MARK: - Running

        /// While settling, sees whether the real test can start. Before the bolus, looks for it, then ends the test if the
        /// service ended it, Trio suspended insulin for a low, the time for the bolus or the 4 hours ran out, the dosing
        /// mode was changed, or something spoiled it.
        func checkRunningTest() async {
            guard let test, test.phase != .finished, !isFinishing else { return }
            // What the check finishes below is this test, and only this one: the reads in between give the user time to
            // discard it and start another, which this check knows nothing about.
            let testID = test.id
            let now = Date()

            if test.phase == .settling {
                await checkSettling(of: testID)
            }
            await shareBolusWindowStart(of: testID)

            // Waiting, the bolus is known, so nothing below waits on reading it.
            var bolusesRead = true
            if let latest = self.test, latest.id == testID, latest.phase == .raising || latest.phase == .dosing {
                // Insulin on board for a counted dose grows old between loops too.
                await refreshDoseIOB()
                bolusesRead = await lookForTestBolus(of: testID)
            }
            // Settling may have ended, and the bolus may have moved it on to the 4 hours.
            guard let current = self.test, current.id == testID, current.phase != .finished, !isFinishing else { return }

            // Counting insulin on board needs it at the bolus; a tick that couldn't read it tries again.
            if current.phase == .waiting, ISFTestEvaluator.iobAtBolusUnread(of: current), let bolusAt = current.bolusAt,
               let iob = await readIOB(before: bolusAt, of: current)
            {
                await updateIOBAtBolus(iob, of: testID)
            }

            // Judged on what the pump delivered: the amount first seen can be the one programmed, and a bolus cut short
            // is written with less once the pump reports it.
            if current.phase == .waiting, let bolusAt = current.bolusAt {
                switch await ISFTestEvaluator.bolusAmount(
                    saved: current.bolusUnits,
                    reread: rereadTestBolus(at: bolusAt),
                    bolusAt: bolusAt,
                    finishing: false
                ) {
                case .cancelled:
                    let ending = ISFTestEvaluator.ending(for: .bolusCancelled, doseDeadline: current.noBolusDeadline)
                    await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
                    return
                case let .units(units):
                    if units != current.bolusUnits {
                        await updateBolusUnits(units, of: testID)
                    }
                case .unread:
                    break
                }
            }

            // Only the test itself: a zero temp after the planned end isn't this test's low. From Begin, so a low before
            // the bolus, settling's among them, is seen as one.
            let end = min(now, current.plannedEnd ?? current.noBolusDeadline)
            // Trio's determinations say whether a zero temp was its suspend for a low or one set on the pump.
            let suspend: BasalTestEvaluator.SuspendReading
            do {
                // A zero temp only Closed Loop asked for as the test began is settling's, not a low.
                suspend = try await provider.fetchSuspendReading(startedAt: current.startedAt, to: end)
            } catch {
                // Without them a low can't be told from a test that ran its course. Before the end nothing is decided on
                // them this time; at it, the test still ends, without a verdict.
                warning(.settings, "ISFTest: couldn't read temp basals to check for a low", error: error)
                suspend = .unreadable
            }

            // Read together on the main actor, where the service keeps its record before it brings the usual mode back,
            // so a mode changed by the service is never seen without the reason.
            let (mode, serviceEnd) = await MainActor.run { (currentMode, testService.lastEnd()) }
            let found = ISFTestEvaluator.runningCheck(
                phase: current.phase,
                sessionID: current.sessionID,
                serviceEnd: serviceEnd,
                suspend: suspend,
                now: now,
                doseDeadline: current.noBolusDeadline,
                // Both always while waiting: without the bolus time a low before the dose can't be told from one after.
                bolusAt: current.bolusAt,
                plannedEnd: current.plannedEnd,
                mode: mode
            )
            if let check = ISFTestEvaluator.decidable(found, bolusesRead: bolusesRead) {
                let ending = ISFTestEvaluator.ending(for: check, doseDeadline: current.noBolusDeadline)
                await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
            } else if case .found = await wasInterrupted(current, until: end) {
                await finish(for: testID, reason: .interrupted)
            }
        }

        /// Reads Trio's determinations and the boluses since Begin, and insulin on board now, and ends settling when
        /// `ISFTestEvaluator.settling` says it has: the real test starts now, on the step the glucose now leads to
        /// (`phaseAfterSettling`), and the service learns where the bolus window starts. Determinations that can't be read
        /// leave it settling.
        private func checkSettling(of testID: UUID) async {
            guard let test, test.id == testID, test.phase == .settling else { return }
            let now = Date()
            let determinations: [Date]
            do {
                determinations = try await provider.fetchDeterminations(from: test.startedAt, to: now).map(\.date)
            } catch {
                warning(.settings, "ISFTest: couldn't read Trio's determinations to settle the test", error: error)
                return
            }
            let boluses: [ISFTestBolus]?
            do {
                boluses = try await provider.fetchBoluses(from: test.startedAt, to: now)
            } catch {
                warning(.settings, "ISFTest: couldn't read boluses given while the test settles", error: error)
                boluses = nil
            }
            // Which of them the pump history flags as SMBs, to say which Trio gave. Unread, none is called one.
            let smbs = try? await provider.shared.fetchSMBs(since: test.startedAt, until: now)
            // The CGM readings since Begin, of which those after Trio's first loop in Basal Testing count. Unread, settling
            // waits for a tick that reads them.
            let readings: [Date]
            do {
                readings = try await provider.shared.fetchGlucose(from: test.startedAt, to: now).map(\.date)
            } catch {
                warning(.settings, "ISFTest: couldn't read glucose to settle the test", error: error)
                return
            }
            let iob = provider.currentIOB()
            // A temp basal still running at the end of settling would change the basal the test runs on. Unread, it
            // doesn't hold settling up.
            let tempBasalRunning = provider.pumpDelivery().map { $0 == .tempBasal }

            await MainActor.run {
                guard var latest = self.test, latest.id == testID, latest.phase == .settling, !isFinishing else { return }
                currentIOB = iob
                settleTempBasalRunning = tempBasalRunning == true
                if let boluses {
                    settlingBoluses = ISFTestEvaluator.settlingBoluses(
                        boluses,
                        smbs: smbs,
                        startedAt: latest.startedAt,
                        settledAt: nil
                    )
                }
                let decision = ISFTestEvaluator.settling(
                    startedAt: latest.startedAt,
                    determinations: determinations,
                    readings: readings,
                    tempBasalRunning: tempBasalRunning,
                    iob: iob,
                    line: latest.iobLine,
                    handling: latest.iobHandling,
                    now: now
                )
                settling = decision
                settleReadings = ISFTestEvaluator.firstLoopInTestMode(determinations, startedAt: latest.startedAt)
                    .map { ISFTestEvaluator.readingsAfterLoop(readings, loopedAt: $0) }
                // A test whose session the service ended, or ran out of time, is ended by the running check instead.
                guard decision == .settled,
                      ISFTestEvaluator.canSettle(
                          sessionID: latest.sessionID,
                          activeSessionID: testService.activeSession?.id,
                          mode: currentMode,
                          now: Date(),
                          noBolusDeadline: latest.noBolusDeadline
                      )
                else { return }
                // A bolus from here on can be the test's; one before it was given while settling.
                let settledAt = Date()
                latest.settledAt = settledAt
                latest.phase = ISFTestEvaluator.phaseAfterSettling(latest, glucose: doseGlucose, at: settledAt)
                provider.storage.save(latest, as: Config.statePath)
                self.test = latest
                testService.setBolusWindowStart(kind: .isf, at: settledAt)
                settling = nil
                settlingBoluses = []
                settleReadings = nil
            }
        }

        /// Makes sure the service knows where the bolus window starts, for a test past settling whose session doesn't:
        /// one begun before settling was kept, whose window starts at Start, or one the app closed on as it settled.
        private func shareBolusWindowStart(of testID: UUID) async {
            await MainActor.run {
                guard let test, test.id == testID, test.phase != .finished, let start = test.bolusWindowStart,
                      let session = testService.activeSession, session.kind == .isf, session.id == test.sessionID,
                      session.bolusWindowStart == nil
                else { return }
                testService.setBolusWindowStart(kind: .isf, at: start)
            }
        }

        /// Insulin on board just before the bolus, from Trio's determinations in the 12 minutes before it
        /// (`ISFTestEvaluator.iobAtBolus`). Nil when there is none that recent, or they couldn't be read.
        private func readIOB(before bolusAt: Date, of test: ISFTestState) async -> Decimal? {
            do {
                let oldest = bolusAt.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - Config.savedDateTolerance)
                let determinations = try await provider.fetchDeterminations(from: max(test.startedAt, oldest), to: bolusAt)
                return ISFTestEvaluator.iobAtBolus(determinations, bolusAt: bolusAt)
            } catch {
                warning(.settings, "ISFTest: couldn't read insulin on board at the bolus", error: error)
                return nil
            }
        }

        /// Insulin on board Trio reports still left at the planned end, from its determinations in the 12 minutes up to it
        /// (`ISFTestEvaluator.iobAtEnd`), the same source and age as at the bolus. Nil when there is none that recent, or
        /// they couldn't be read.
        private func readIOB(atEnd plannedEnd: Date, of test: ISFTestState) async -> Decimal? {
            do {
                let oldest = plannedEnd.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - Config.savedDateTolerance)
                let determinations = try await provider.fetchDeterminations(
                    from: max(test.startedAt, oldest),
                    to: plannedEnd.addingTimeInterval(Config.savedDateTolerance)
                )
                return ISFTestEvaluator.iobAtEnd(determinations, plannedEnd: plannedEnd)
            } catch {
                warning(.settings, "ISFTest: couldn't read insulin on board at the end of the 4 hours", error: error)
                return nil
            }
        }

        /// Saves the insulin on board at the bolus, for a test that counts it.
        private func updateIOBAtBolus(_ iob: Decimal, of testID: UUID) async {
            await MainActor.run {
                guard var latest = test, latest.id == testID, latest.phase == .waiting, !isFinishing else { return }
                latest.iobAtBolus = iob
                provider.storage.save(latest, as: Config.statePath)
                test = latest
            }
        }

        /// Finds the test bolus, the first bolus from the end of settling to the deadline from any source, and moves the
        /// test on to the 4 hours with the bolus, the glucose it was given at, the ISF entries the 4 hours cover and, in
        /// a test that counts it, the insulin on board just before it. A bolus given while a condition the Dose step holds
        /// the dose for didn't hold (`ISFTestEvaluator.failedBolusCondition`) ends the test with no verdict. Returns whether the boluses could be read, so a
        /// tick that couldn't read them doesn't decide there was none.
        private func lookForTestBolus(of testID: UUID) async -> Bool {
            guard let test, test.id == testID, let windowStart = test.bolusWindowStart else { return true }
            let bolus: ISFTestBolus?
            do {
                // Read a little past the deadline, which is saved to the millisecond, so a bolus at the same moment as it
                // reaches `testBolus`, which counts it as inside. One before the end of settling isn't the test's.
                let boluses = try await provider.fetchBoluses(
                    from: windowStart,
                    to: test.doseDeadline.addingTimeInterval(Config.savedDateTolerance)
                )
                bolus = ISFTestEvaluator.testBolus(boluses, since: windowStart, deadline: test.doseDeadline)
            } catch {
                warning(.settings, "ISFTest: couldn't read boluses to look for the test bolus", error: error)
                return false
            }
            guard let bolus else { return true }

            // The mean of the last 3 readings at or before the bolus. If they can't be read now, finishing tries again.
            let startGlucose: Int?
            do {
                let readings = try await provider.shared.fetchGlucose(
                    from: bolus.date.addingTimeInterval(-Self.startReadingsLookback),
                    to: bolus.date
                )
                startGlucose = BasalTestEvaluator.endGlucose(from: readings, endingAt: bolus.date)
            } catch {
                warning(.settings, "ISFTest: couldn't read glucose at the bolus", error: error)
                startGlucose = nil
            }
            // Only a test that counts it needs it; if it can't be read now, the next tick and finishing try again.
            let iobAtBolus = test.iobHandling == .count ? await readIOB(before: bolus.date, of: test) : nil

            // What the Dose step holds the dose for, as it was at the bolus, which can come from Home, the pump or the
            // Watch as well as from Open Treatments. A read that fails leaves its condition unread.
            let conditionReadings: [BasalTestReading]?
            if let takenAt = test.tabletsTakenAt {
                conditionReadings = try? await provider.shared.fetchGlucose(
                    from: min(takenAt, bolus.date).addingTimeInterval(-Self.startReadingsLookback),
                    to: bolus.date.addingTimeInterval(Config.savedDateTolerance)
                )
            } else {
                conditionReadings = []
            }
            let arrow = try? await provider.fetchArrowReading(atOrBefore: bolus.date)
            let atBolusDeterminations = try? await provider.fetchDeterminations(
                from: bolus.date.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - Config.savedDateTolerance),
                to: bolus.date.addingTimeInterval(Config.savedDateTolerance)
            )

            // On the main actor, from the state as it is now, so a tap on the Raise or Dose step in the meantime isn't
            // lost and a test discarded or finished in the meantime isn't brought back.
            let moved: (state: ISFTestState, failed: ISFTestBolusCondition?)? = await MainActor.run {
                guard let shown = self.test, shown.id == testID, !isFinishing,
                      shown.phase == .raising || shown.phase == .dosing
                else { return nil }
                // The ISF and target the result uses become those in force at the bolus, from the schedules saved at Begin,
                // so an ISF edited since doesn't become what the test ran on, and the ISF schedule narrows to its 4 hours.
                var latest = ISFTestEvaluator.atBolus(shown, bolusAt: bolus.date)
                latest.phase = .waiting
                latest.bolusAt = bolus.date
                // A bolus with no amount recorded still started the test, but there is no amount to judge it by.
                latest.bolusUnits = bolus.units > 0 ? bolus.units : nil
                latest.startGlucose = startGlucose
                latest.iobAtBolus = iobAtBolus
                provider.storage.save(latest, as: Config.statePath)
                self.test = latest
                // The line for insulin on board is the docs' smallest ISF change of the docs' dose at the bolus.
                let docsDose = startGlucose.flatMap {
                    ISFTestEvaluator.dose(glucose: $0, target: latest.target, isf: latest.isf)
                }
                let failed = ISFTestEvaluator.failedBolusCondition(
                    bolusAt: bolus.date,
                    readings: conditionReadings,
                    tabletsTakenAt: latest.tabletsTakenAt,
                    tabletsGlucose: latest.tabletsGlucose,
                    arrow: arrow,
                    determinations: atBolusDeterminations,
                    handling: latest.iobHandling,
                    line: ISFTestEvaluator.doseIOBLine(dose: docsDose, handling: latest.iobHandling)
                )
                return (latest, failed)
            }
            // A bolus the Dose step would have held: the test ends with no verdict, and the usual mode comes back.
            if let failed = moved?.failed {
                await finish(for: testID, reason: .interrupted, note: failed.note)
                return true
            }
            // A test found after its 4 hours finishes right away, so there is nothing to tell the user later.
            if let plannedEnd = moved?.state.plannedEnd, plannedEnd > Date() {
                scheduleFinishedNotification(at: plannedEnd)
            }
            return true
        }

        /// The bolus rows around the saved bolus time, read again, so the test bolus's amount is the one the pump history
        /// holds now. Any bolus row, because the history can flag the test bolus as an SMB when it writes the amount
        /// delivered. Nil when they couldn't be read.
        private func rereadTestBolus(at bolusAt: Date) async -> [ISFTestBolusRecord]? {
            do {
                return try await provider.fetchBolusRecords(
                    from: bolusAt.addingTimeInterval(-Config.savedDateTolerance),
                    to: bolusAt.addingTimeInterval(Config.savedDateTolerance)
                )
            } catch {
                warning(.settings, "ISFTest: couldn't read the test bolus again", error: error)
                return nil
            }
        }

        /// Saves the amount the pump history now holds for the test bolus, so the Wait step shows what was delivered.
        private func updateBolusUnits(_ units: Decimal?, of testID: UUID) async {
            await MainActor.run {
                guard var latest = test, latest.id == testID, latest.phase == .waiting, !isFinishing else { return }
                latest.bolusUnits = units
                provider.storage.save(latest, as: Config.statePath)
                test = latest
            }
        }

        // MARK: - Finish

        /// Ending early gives no result.
        func endEarly() async {
            await finish(reason: .endedEarly)
        }

        /// Cancel Test, before the bolus: the usual mode comes back and nothing is kept.
        @MainActor func discard() {
            if let test {
                endSession(of: test)
            } else {
                testService.end(kind: .isf)
            }
            clearTest()
            cancelFinishedNotification()
        }

        /// Ends the test's session, so the service puts the usual mode back, on the main actor, where the service changes
        /// the mode and the screen reads it. When the session is lost (no session runs and the service kept no end of
        /// it) with Basal Testing still on, the screen puts the mode Begin saved back itself
        /// (`ISFTestEvaluator.modeToRestore`); otherwise nothing it doesn't own is changed.
        @MainActor private func endSession(of test: ISFTestState) {
            let restore = ISFTestEvaluator.modeToRestore(
                mode: currentMode,
                testSessionID: test.sessionID,
                activeSessionID: testService.activeSession?.id,
                lastEndSessionID: testService.lastEnd()?.sessionID,
                previousMode: test.previousMode
            )
            testService.end(kind: .isf)
            if let restore {
                debug(.settings, "ISFTest: the test's session was lost, restoring \(restore.rawValue) itself")
                settingsManager.settings.dosingMode = restore
            }
        }

        /// Whether Basal Testing is still on with no test running it, so the Result says so instead of the usual dosing
        /// coming back (`SettingsTestModeRule.basalTestingLeftOn`).
        var basalTestingLeftOn: Bool {
            SettingsTestModeRule.basalTestingLeftOn(mode: currentMode, activeSessionID: testService.activeSession?.id)
        }

        /// `endedAt` is when a low ended the test, or when the service ended it; without it the test ends now, or at the
        /// planned end (the dose deadline before the bolus) if that came first. `note` says what interrupted it when the
        /// records don't. `reason` is what the caller saw; the history up to the end can still make it a low or an
        /// interruption (`settle`). With `testID`, it finishes only that test: a check that read the history for one
        /// test must not end another that was started while it waited.
        func finish(
            for testID: UUID? = nil,
            reason: ISFTestEndReason,
            at endedAt: Date? = nil,
            note: String? = nil
        ) async {
            // Claimed on the main actor, where Cancel Test and Start run, so the claim and the save below are ordered
            // with them.
            let claimed: ISFTestState? = await MainActor.run {
                guard let current = test, current.phase != .finished, !isFinishing,
                      testID == nil || current.id == testID
                else { return nil }
                isFinishing = true
                return current
            }
            guard var current = claimed else { return }

            // Fixed before normal dosing comes back, so nothing the usual mode does next falls inside the test.
            let endedBy = ISFTestEvaluator.endTime(
                endedAt: endedAt,
                limit: current.plannedEnd ?? current.noBolusDeadline,
                now: Date()
            )

            // Normal dosing comes back first, on the main actor; the rest is bookkeeping.
            let ending = current
            await MainActor.run { endSession(of: ending) }
            cancelFinishedNotification()

            // The history up to the end decides how the test ended, so a suspend the periodic checks hadn't seen yet
            // isn't lost. Read once normal dosing is back, so the read never holds it up.
            let settled = await settle(current, reason: reason, at: endedBy)
            var reason = settled.reason
            let end = settled.at ?? endedBy
            var note = note ?? settled.note

            // What the pump delivered, read again: a bolus cut short is judged per unit delivered, one cancelled before
            // any insulin went in leaves nothing to judge, and an amount that can't be read isn't trusted.
            var bolusUnread = false
            if let bolusAt = current.bolusAt {
                switch await ISFTestEvaluator.bolusAmount(
                    saved: current.bolusUnits,
                    reread: rereadTestBolus(at: bolusAt),
                    bolusAt: bolusAt,
                    finishing: true
                ) {
                case let .units(units):
                    current.bolusUnits = units
                case .cancelled:
                    // Something else that interrupted the test keeps its own words.
                    if reason != .interrupted {
                        let cancelled = ISFTestEvaluator.ending(for: .bolusCancelled, doseDeadline: current.noBolusDeadline)
                        reason = cancelled.reason
                        note = cancelled.note
                    }
                case .unread:
                    bolusUnread = true
                }
                // Counting insulin on board needs it at the bolus, read once more if no tick could.
                if ISFTestEvaluator.iobAtBolusUnread(of: current) {
                    current.iobAtBolus = await readIOB(before: bolusAt, of: current)
                }
                // A test that ran its 4 hours is judged on the insulin that acted in them: what Trio reports still on
                // board at the planned end is left out. Unread, there is no verdict.
                if reason == .completed, let plannedEnd = current.plannedEnd {
                    current.iobAtEnd = await readIOB(atEnd: plannedEnd, of: current)
                }
            }

            // From the bolus, or from Start if none came, and from a little before it for the start glucose. A little
            // past the end, which is saved to the millisecond, so a reading at the same moment as it is read.
            let anchor = current.bolusAt ?? current.startedAt
            let fetched: [BasalTestReading]
            do {
                fetched = try await provider.shared.fetchGlucose(
                    from: anchor.addingTimeInterval(-Self.startReadingsLookback),
                    to: end.addingTimeInterval(Config.savedDateTolerance)
                )
            } catch {
                warning(.settings, "ISFTest: couldn't read the test's glucose", error: error)
                fetched = []
            }
            // A reading at the same moment as the saved bolus counts as at it, for both, and one at the end as at it.
            let readings = ISFTestEvaluator.readings(ISFTestEvaluator.readings(fetched, since: anchor), atOrBefore: end)
            let startGlucose = current.startGlucose ?? current.bolusAt.flatMap { bolusAt in
                BasalTestEvaluator.endGlucose(from: ISFTestEvaluator.readings(fetched, atOrBefore: bolusAt), endingAt: bolusAt)
            }
            // Where the 4 hours ended, or, for a low, the glucose at Trio's suspend.
            let endGlucose = ISFTestEvaluator.endGlucose(fetched, bolusAt: current.bolusAt, end: end, reason: reason)
            let checked = await wasInterrupted(current, until: end)
            let interference: String?
            if case let .found(message) = checked {
                interference = message
            } else {
                interference = note
            }
            let interferenceUnread = checked == .unreadable || bolusUnread

            // `reason` as the finish decided it, so a test that ran its 4 hours needs the insulin left at the end read.
            current.endReason = reason
            let evaluation = ISFTestEvaluator.evaluate(
                startGlucose: startGlucose,
                endGlucose: endGlucose,
                units: ISFTestEvaluator.judgedUnits(of: current),
                elapsed: end.timeIntervalSince(anchor),
                reason: reason,
                interference: interference,
                interferenceUnread: interferenceUnread,
                // Insulin on board the units judged rest on couldn't be read: no units to judge by.
                iobUnread: ISFTestEvaluator.iobUnread(of: current),
                isf: current.isf,
                // A low says the ISF number is too low only at or below the target, after no more than the docs' dose.
                target: current.target,
                givenUnits: ISFTestEvaluator.givenUnits(of: current),
                increment: current.bolusIncrement ?? 0
            )

            current.phase = .finished
            current.endedAt = end
            current.endReason = reason
            current.startGlucose = startGlucose
            current.endGlucose = endGlucose
            current.readings = readings
            current.outcome = evaluation.outcome
            current.interference = interference
            current.interferenceUnread = interferenceUnread

            // Only a verdict on the ISF is kept. A low has one whatever the readings were, so it needs only one of them.
            var record: SettingsTestRecord?
            if evaluation.outcome.isConclusive, let direction = evaluation.direction, let bolusAt = current.bolusAt,
               let recordStart = startGlucose ?? endGlucose
            {
                record = SettingsTestRecord(
                    kind: .isf,
                    startedAt: bolusAt,
                    completedAt: end,
                    timeBlock: BasalTestEvaluator.timeBlock(for: bolusAt),
                    startGlucose: recordStart,
                    endGlucose: endGlucose ?? recordStart,
                    direction: direction,
                    summary: ISFTestEvaluator.summary(
                        for: evaluation.outcome,
                        reason: reason,
                        startGlucose: startGlucose,
                        endGlucose: endGlucose
                    ),
                    // Only what the hours it ran covered, so a test ended by a low doesn't vouch for the rest.
                    coveredEntries: ISFTestEvaluator.coveredEntries(current.coveredEntries ?? [], from: bolusAt, to: end),
                    bolusUnits: current.bolusUnits,
                    tabletCarbs: current.tabletCarbs,
                    iobHandling: current.iobHandling?.rawValue,
                    iobCounted: current.iobHandling == .count ? current.iobAtBolus : nil,
                    judgedUnits: ISFTestEvaluator.judgedUnits(of: current)
                )
            }

            // Kept only if it is still the test on screen: a Cancel Test or a new Start while the history was read owns
            // the screen and the saved state now. One step on the main actor, so neither can come in between.
            let finished = current
            let archived = record
            await MainActor.run {
                isFinishing = false
                guard let shown = test, shown.id == finished.id, shown.phase != .finished else { return }
                provider.storage.save(finished, as: Config.statePath)
                if let archived {
                    testService.archive(archived)
                }
                test = finished
            }
        }

        /// How the test ends, from what the pump history and Trio's determinations up to `end` say: see
        /// `ISFTestEvaluator.finishing`. A reason already decided needs no read.
        private func settle(
            _ test: ISFTestState,
            reason: ISFTestEndReason,
            at end: Date
        ) async -> ISFTestEvaluator.Ending {
            guard ISFTestEvaluator.rereadsHistory(reason) else {
                return ISFTestEvaluator.Ending(reason: reason, at: end, note: nil)
            }
            let suspend: BasalTestEvaluator.SuspendReading
            do {
                suspend = try await provider.fetchSuspendReading(startedAt: test.startedAt, to: end)
            } catch {
                warning(.settings, "ISFTest: couldn't read temp basals to check the finished test for a low", error: error)
                suspend = .unreadable
            }
            return ISFTestEvaluator.finishing(
                reason: reason,
                at: end,
                suspend: suspend,
                bolusAt: test.bolusAt,
                doseDeadline: test.noBolusDeadline
            )
        }

        /// What spoiled the test, if anything: carbs, the pump suspended, alarmed or changed, a bolus after the test's own,
        /// or Trio dosing, which it doesn't in Basal Testing. Each record is read on its own, so one that can't be read is
        /// logged without hiding what the others show; with nothing found, the test is left unchecked. Trio's SMBs and its temp basals are read apart,
        /// so one that can't be read doesn't hide what the other shows. Carbs count from Begin; Trio's dosing only from the
        /// end of settling, because what a loop already running at Begin gave lands while settling, in the insulin on
        /// board the test waits for or counts. A test that never settled has no dosing of Trio's to check.
        private func wasInterrupted(_ test: ISFTestState, until end: Date) async -> BasalTestEvaluator.Interference {
            let start = test.startedAt
            let windowStart = test.bolusWindowStart
            let bolusAt = test.bolusAt
            let provider: Provider = self.provider
            let dosed = String(localized: "Trio dosed during the test, so Basal Testing wasn't on the whole time.")
            return await BasalTestEvaluator.firstInterference([
                (name: "carbs", read: {
                    try await provider.shared.hasCarbEntries(from: start, to: end)
                        ? String(localized: "Carbs were logged during the test.")
                        : nil
                }),
                // From Begin: a suspend, an alarm, or a site or reservoir change means basal or the bolus may not have
                // gone in as recorded.
                (name: "pump events", read: {
                    try await provider.fetchPumpInterruptions(from: start, to: end).isEmpty
                        ? nil
                        : ISFTestEvaluator.pumpInterruptedNote
                }),
                (name: "boluses", read: {
                    // Before the bolus there is no test bolus for another to come after.
                    guard let bolusAt else { return nil }
                    let boluses = try await provider.fetchBoluses(from: start, to: end)
                    return ISFTestEvaluator.hasExtraBolus(boluses, after: bolusAt)
                        ? String(localized: "Another bolus was given during the test.")
                        : nil
                }),
                (name: "Trio's SMBs", read: {
                    guard let windowStart else { return nil }
                    // The test bolus itself may be flagged as an SMB; any other bolus is the boluses read's to find.
                    let smbs = try await ISFTestEvaluator.smbs(
                        provider.shared.fetchSMBs(since: windowStart, until: end),
                        besidesTestBolusAt: bolusAt
                    )
                    return BasalTestEvaluator.dosedDuringFast(smbs: smbs, temps: [], since: windowStart, until: end)
                        ? dosed
                        : nil
                }),
                (name: "Trio's temp basals", read: {
                    guard let windowStart else { return nil }
                    let temps = try await provider.shared.fetchTempBasals(from: windowStart, to: end)
                    return BasalTestEvaluator.dosedDuringFast(smbs: [], temps: temps, since: windowStart, until: end)
                        ? dosed
                        : nil
                })
            ])
        }

        /// Clears a finished result so the user can start over.
        func acknowledgeResult() {
            clearTest()
        }

        private func clearTest() {
            provider.storage.remove(Config.statePath)
            test = nil
            settling = nil
            settlingBoluses = []
            settleReadings = nil
            settleTempBasalRunning = false
            // The next test's Check starts on the docs' way.
            iobChoice = .wait
            Task { await refresh() }
        }

        // MARK: - Notifications

        private func scheduleFinishedNotification(at date: Date) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "ISF test finished")
            content.body = String(localized: "Open Trio to see what your ISF did.")
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.finishedNotificationID,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            )
            UNUserNotificationCenter.current().add(request)
        }

        private func cancelFinishedNotification() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [Self.finishedNotificationID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.finishedNotificationID])
        }
    }
}
