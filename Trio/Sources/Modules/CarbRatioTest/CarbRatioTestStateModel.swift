import Combine
import CoreData
import Foundation
import Observation
import SwiftUI

/// What the carb ratio screen reads for its steps, beside the runner's state (`StateModel.refresh`). `CarbRatioTest.Provider`
/// conforms; a test gives the state model its own (`StateModel.screenReads`).
protocol CarbRatioTestScreenReads: AnyObject {
    /// The ISF schedule in mg/dL per unit, for the Check screen's word on the newest ISF test.
    func isfEntries() -> [SettingsTestScheduleEntry]
    func isf(at date: Date) -> Decimal?
    func target(at date: Date) -> Decimal?
    func carbRatio(at date: Date) -> Decimal?
    /// The carb ratio schedule in grams per unit, for the hours a test begun now can run on.
    func carbRatioEntries() -> [SettingsTestScheduleEntry]
    /// Newest first.
    func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading]
    func currentIOB() -> Decimal?
    func currentCOB() async throws -> Decimal?
    /// Carbs on board for the Dose step, from before the tablets' carbs once they are logged
    /// (`CarbRatioTestReads.fetchDoseCOB`). Nil while unread.
    func doseCOB(windowStart: Date?) async -> Decimal?
    func hasActiveAdjustment() async throws -> Bool
    func hasPumpSetTempBasal() -> Bool
    func pumpDelivery() -> ISFTestPumpDelivery?
    func hasCgmAndPump() -> Bool
    func maxBolus() -> Decimal?
    func maxCarbs() -> Decimal?
}

extension CarbRatioTest.Provider: CarbRatioTestScreenReads {
    func hasPumpSetTempBasal() -> Bool { shared.hasPumpSetTempBasal() }
    func hasCgmAndPump() -> Bool { shared.hasCgmAndPump() }
    func doseCOB(windowStart: Date?) async -> Decimal? { await fetchDoseCOB(windowStart: windowStart) }
}

extension CarbRatioTest {
    /// The pages of the Check step, one question each: the checks, the tablets, how long to watch, insulin on board
    /// (only when it is over the test's line), and the summary with Begin. Screen state, never saved: a relaunch opens
    /// the checks.
    enum CheckPage: CaseIterable, Hashable {
        case checks
        case tablets
        case length
        case iob
        case ready
    }

    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        /// What runs the test, in the service: the screen shows its state (`apply`) and passes the user's actions on. The
        /// service's (`subscribe`), or one a test sets.
        @ObservationIgnored var runner: CarbRatioTestRunning?
        /// Told when a notice-opened screen sends the user to Treatments (`openTreatments`). Settable for tests; lazy, so
        /// the shared one is read on the main actor, where it lives.
        @ObservationIgnored @MainActor lazy var opener = SettingsTestScreenOpener.shared
        /// Fills the tablets' carbs in on the Treatments sheet Open Treatments opens. Settable for tests.
        @ObservationIgnored @MainActor lazy var prefill = SettingsTestTreatmentsPrefill.shared
        /// What `refresh` reads: the provider, or what a test sets.
        @ObservationIgnored var screenReads: CarbRatioTestScreenReads?
        private var reads: CarbRatioTestScreenReads { screenReads ?? provider }

        /// How far back the screen reads glucose: the longest a test runs, 90 minutes for the bolus and 4 hours after
        /// it, with time to spare.
        private static let recentReadingsMinutes = 6 * 60

        // MARK: - State

        /// The test in progress or just finished, as the runner saved it. `nil` while the user is still getting ready.
        private(set) var test: CarbRatioTestState?

        /// Newest first.
        private(set) var recentReadings: [BasalTestReading] = []
        /// Nil while Trio hasn't worked insulin on board out. While the runner reports settling, the one its last check
        /// read (`ISFTestSettlingProgress.iob`), so the Settle step's row and question agree with the step it shows;
        /// otherwise the one `refresh` read.
        var currentIOB: Decimal? { settling == nil ? readIOB : settleIOB }
        private var readIOB: Decimal?
        private var settleIOB: Decimal?
        /// Insulin on board for a counted dose, as the runner last read it. Nil when there is none, or in a test that
        /// doesn't count it.
        private(set) var doseIOB: Decimal?
        /// Carbs on board from Trio's newest determination of the last 12 minutes, for the Check screen. Nil while there
        /// is none that recent: unread is not none.
        private(set) var currentCOB: Decimal?
        /// Carbs on board for the Dose step, from before the tablets' carbs once they are logged
        /// (`CarbRatioTestReads.fetchDoseCOB`). Nil while unread.
        private(set) var doseCOB: Decimal?
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
        /// The settings in force now, for the Check screen. A running test uses the ones it saved at Begin.
        private(set) var settingsNow = ScreenSettings()
        /// What the newest ISF test says about the ISF this test turns glucose into units with. It only informs.
        private(set) var isfGate: SettingsTestSchedule.ISFGate = .noAccurateTest

        /// The tablets picked on the Check screen.
        var selectedBrand: GlucoseTabletBrand = .dex4
        /// The count the stepper was set to. The count shown is kept between 1 and what the limits allow
        /// (`tabletCount`).
        var wantedTabletCount = Config.defaultTabletCount
        /// How long the test runs after the bolus, as picked on the Check screen (`Config.lengths`).
        var selectedLength: TimeInterval = Config.defaultLength
        /// How the test handles insulin on board over its line, as picked on the Check screen. The docs' way first.
        var iobChoice: ISFTestIOBHandling = .wait
        /// The Check step's page, as the user moved to it (`showsCheckPage` is the one shown).
        var checkPage: CheckPage = .checks
        /// The Check step's pages that have come up on screen since the checks did (`checkPageAppeared`). Screen state.
        private(set) var seenCheckPages: Set<CheckPage> = [.checks]
        /// While this screen's own Begin runs: a test the runner publishes and then takes back, as a Begin that fails
        /// does, isn't a test cleared elsewhere, so the pages stay where they are (`apply`). Main actor only.
        @ObservationIgnored private var beginInFlight = false

        /// Where settling is, from its last check. Nil when the test isn't settling, or before the first check.
        private(set) var settling: ISFTestSettling?
        /// The boluses given while the test settles, oldest first.
        private(set) var settlingBoluses: [ISFTestSettlingBolus] = []
        /// How many CGM readings came after Trio's first loop in Basal Testing, from settling's last check.
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

        /// The settings the Check screen reads, in grams per unit, mg/dL per unit, mg/dL, units and grams.
        struct ScreenSettings: Equatable {
            var carbRatio: Decimal?
            var isf: Decimal?
            var target: Decimal?
            var maxBolus: Decimal?
            var maxCarbs: Decimal?
            /// The carb ratio schedule, for the hours a test begun now can run on.
            var carbRatioEntries: [SettingsTestScheduleEntry] = []
        }

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

        /// Insulin units to 2 decimals, rounded half up, e.g. "2.24" (`ISFTestEvaluator.shownUnits`).
        func formatUnits(_ units: Decimal) -> String {
            ISFTestEvaluator.shownUnits(units)
        }

        /// Insulin units to 2 decimals with a minus sign, not a hyphen, when below zero, e.g. "−0.30".
        func formatSignedUnits(_ units: Decimal) -> String {
            (units < 0 ? "\u{2212}" : "") + formatUnits(abs(units))
        }

        /// Grams of carbs, e.g. "40" or "37.5".
        func formatGrams(_ grams: Decimal) -> String {
            grams.formatted(.number.precision(.fractionLength(0 ... 2)))
        }

        /// A carb ratio in grams per unit, e.g. "10" or "8.5".
        func formatCarbRatio(_ ratio: Decimal) -> String {
            ratio.formatted(.number.precision(.fractionLength(0 ... 1)))
        }

        /// A test length as the Check screen's picker and the steps say it, e.g. "4 h".
        func lengthText(_ length: TimeInterval) -> String {
            String(localized: "\(Int(length / 3600)) h")
        }

        /// The docs' smallest carb ratio change, "1 g/U", kept on one line.
        var stepText: String {
            SettingsTestFormat.keepTogether(formatCarbRatio(Config.docsSmallestStep), unit: "g/U")
        }

        var currentMode: DosingMode {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.dosingMode ?? .open
        }

        // MARK: - Step

        var step: Step {
            switch test?.phase {
            case .settling: return .settle
            case .dosing: return .dose
            case .waiting: return .wait
            case .finished: return .result
            case nil: return .check
            }
        }

        /// The steps the step bar shows as skipped, not done: the dose and the wait of a test that ended with no bolus.
        var skippedSteps: Set<Step> {
            guard let test, test.phase == .finished, test.bolusAt == nil else { return [] }
            return [.dose, .wait]
        }

        // MARK: - Readings

        var currentGlucose: Int? { recentReadings.first?.glucose }

        var readingIsStale: Bool {
            guard let latest = recentReadings.first?.date else { return true }
            return Date().timeIntervalSince(latest) > ISFTestEvaluator.arrowMaxAge
        }

        /// The Wait step's "Now": the newest reading while it is recent, nil once it is out of date.
        var glucoseNow: Int? {
            readingIsStale ? nil : currentGlucose
        }

        /// What the Dose step reads to work out whether the dose can be given, as one value, at this moment: the rules
        /// that judge it take it whole (`CarbRatioTestDoseInputs`), so a runner with the screen closed judges the same.
        var doseInputs: CarbRatioTestDoseInputs {
            CarbRatioTestDoseInputs(
                readings: recentReadings,
                direction: trendDirection,
                iob: currentIOB,
                doseIOB: doseIOB,
                cob: doseCOB,
                increment: bolusIncrement,
                now: Date(),
                maxBolus: settingsNow.maxBolus
            )
        }

        /// The mean of the last 3 readings, nil when the newest is too old (`ISFTestEvaluator.doseGlucose`).
        var doseGlucose: Int? {
            ISFTestEvaluator.doseGlucose(doseInputs.isfInputs)
        }

        /// The arrow as the screen shows it, if the CGM gave one for a recent reading.
        var trendArrow: String? {
            guard let direction = ISFTestEvaluator.shownDirection(doseInputs.isfInputs) else { return nil }
            switch direction {
            case .none,
                 .notComputable,
                 .rateOutOfRange: return nil
            default: return direction.symbol
            }
        }

        // MARK: - Tablets

        /// The most tablets of the chosen brand the Check screen offers: up to `Config.maxTabletCount`, while their carbs
        /// stay within Max Carbs and their dose within Max Bolus (`CarbRatioTestEvaluator.maxTablets`). Without the limits
        /// read, the app's cap, as Begin then leaves them to Treatments. Zero without a carb ratio.
        var maxTablets: Int {
            guard let ratio = settingsNow.carbRatio, ratio > 0 else { return 0 }
            guard let maxBolus = settingsNow.maxBolus, let maxCarbs = settingsNow.maxCarbs else { return Config.maxTabletCount }
            return CarbRatioTestEvaluator.maxTablets(
                brand: selectedBrand,
                carbRatio: lowestCarbRatio ?? ratio,
                maxBolus: maxBolus,
                maxCarbs: maxCarbs
            )
        }

        /// The lowest carb ratio the longest test begun now can meet (`CarbRatioTestEvaluator.lowestCarbRatio`), where the
        /// tablets' dose is largest, so the count fits Max Bolus whatever length is picked. Nil without a carb ratio.
        var lowestCarbRatio: Decimal? {
            guard let ratio = settingsNow.carbRatio else { return nil }
            let covered = CarbRatioTestEvaluator.coveredAtBegin(
                settingsNow.carbRatioEntries,
                startedAt: Date(),
                length: Config.lengths.max() ?? selectedLength
            )
            return CarbRatioTestEvaluator.lowestCarbRatio(ratio, covered: covered)
        }

        /// The tablets the test takes: the count picked, kept between 1 and `maxTablets`. Nil when not even one fits.
        var tabletCount: Int? {
            let most = maxTablets
            guard most >= 1 else { return nil }
            return min(max(wantedTabletCount, 1), most)
        }

        /// The tablets' grams. Zero without a count.
        var tabletCarbs: Decimal {
            tabletCount.map { selectedBrand.totalCarbs(for: $0) } ?? 0
        }

        /// The docs' dose for the tablets, carbs ÷ CR, unrounded, which insulin on board is measured against. Nil without
        /// tablets or a carb ratio.
        var expectedDose: Decimal? {
            guard let ratio = settingsNow.carbRatio else { return nil }
            return CarbRatioTestEvaluator.unroundedDose(carbs: tabletCarbs, carbRatio: ratio)
        }

        /// The docs' dose for the tablets, to 2 decimals, as the Check screen's formula shows it.
        var checkDose: Decimal? {
            guard let ratio = settingsNow.carbRatio else { return nil }
            return CarbRatioTestEvaluator.dose(carbs: tabletCarbs, carbRatio: ratio)
        }

        /// Whether the Check screen's dose follows "≈": carbs ÷ CR with more than 2 decimals.
        var checkDoseIsApproximate: Bool {
            guard let exact = expectedDose, let shown = checkDose else { return false }
            return exact != shown
        }

        /// How far a 1 g/U change of the carb ratio moves where glucose ends with these tablets, in mg/dL
        /// (`CarbRatioTestEvaluator.endShiftPerStep`). Nil without tablets, a carb ratio or an ISF.
        var endShiftPerStep: Int? {
            guard let ratio = settingsNow.carbRatio, let isf = settingsNow.isf else { return nil }
            return CarbRatioTestEvaluator.endShiftPerStep(carbs: tabletCarbs, carbRatio: ratio, isf: isf)
        }

        /// The Tablets page's line under the formula: how clearly these tablets can show a docs step of the carb ratio.
        /// It promises no end range: the result is judged on the insulin that acted, which isn't known until the end. Nil
        /// without the shift.
        var precisionLine: String? {
            guard let shift = endShiftPerStep else { return nil }
            return String(
                localized: "A \(stepText) change in your carb ratio moves where glucose ends by about \(formatWithUnits(shift)) with these tablets. More tablets give a clearer answer."
            )
        }

        /// The line insulin on board must be under for the docs' dose, as the Check screen measures it
        /// (`CarbRatioTestEvaluator.iobLine`). Nil without a dose.
        var checkIOBLine: Decimal? {
            guard let dose = expectedDose, let ratio = settingsNow.carbRatio else { return nil }
            return CarbRatioTestEvaluator.iobLine(dose: dose, carbRatio: ratio)
        }

        /// The line carbs on board must be under for these tablets (`CarbRatioTestEvaluator.cobLine`). Nil without
        /// tablets or a carb ratio.
        var checkCOBLine: Decimal? {
            guard let ratio = settingsNow.carbRatio, tabletCarbs > 0 else { return nil }
            return CarbRatioTestEvaluator.cobLine(carbs: tabletCarbs, carbRatio: ratio)
        }

        /// What insulin on board now means for the test. Nil without an expected dose, or before Trio has read it.
        var iobDecision: ISFTestIOBDecision? {
            CarbRatioTestEvaluator.iobDecision(iob: currentIOB, expectedDose: expectedDose, carbRatio: settingsNow.carbRatio)
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

        /// Facts about the app that have to be true before the test starts, the tablets fitting the limits, carbs on board
        /// over the line, and insulin on board over the whole dose.
        var blockingChecks: [Check] {
            // Another test running comes first: its Basal Testing fails the mode check too, and the footer names the test.
            var checks = [
                otherTestCheck,
                devicesCheck,
                pumpSuspendedCheck,
                adjustmentsCheck,
                pumpTempBasalCheck,
                modeCheck,
                tabletsCheck
            ]
            if let carbRatioMinimumCheck {
                checks.append(carbRatioMinimumCheck)
            }
            if let cobCheck {
                checks.append(cobCheck)
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
            rows.append(isfCheck)
            return rows
        }

        var readyToStart: Bool {
            blockingChecks.allSatisfy { $0.state == .passed }
        }

        /// Shown one by one, because each says what to do.
        var failingChecks: [Check] { blockingChecks.filter { $0.state != .passed } }

        /// Folded into one line on the Check screen.
        var passingChecks: [Check] { blockingChecks.filter { $0.state == .passed } }

        /// Why Begin can't be tapped yet: what the first check that fails says.
        var startBlocker: String? {
            guard let check = failingChecks.first else { return nil }
            return check.detail ?? check.title
        }

        /// The other settings test running now, or nil. The hub opens this screen while one does, so its steps can be read.
        var otherRunningTest: SettingsTestKind? {
            activeSessionKind.flatMap { $0 == .carbRatio ? nil : $0 }
        }

        /// Whether the usual dosing mode is on, so the Result can say it is back.
        var usualModeIsOn: Bool { currentMode != .basalTesting }

        // MARK: Rows that block

        private var otherTestCheck: Check {
            Check(
                id: "otherTest",
                title: String(localized: "No other test running"),
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
                        localized: "While insulin is suspended, your pump gives no basal and no bolus, so the test can't measure what the bolus does for the tablets. A suspend, an alarm, or a site or reservoir change during the test ends it without a result."
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
                        localized: "An override or a temp target changes how much insulin Trio gives and how it reads your sensitivity, so the test wouldn't show what your carb ratio does on its own."
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
                        localized: "Basal Testing cancels a temp basal Trio set, but not one set on the pump itself. That one would keep running and change your basal during the test, so the result wouldn't show what your carb ratio does on its own."
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

        /// The tablets fit Max Bolus and Max Carbs, app limits Begin holds them to as Treatments does. Without a carb ratio
        /// there are no tablets to count.
        private var tabletsCheck: Check {
            let fits = tabletCount != nil
            let detail: String?
            if fits {
                detail = nil
            } else if settingsNow.carbRatio == nil {
                detail = String(localized: "Trio couldn't read your carb ratio, so it can't count the tablets.")
            } else {
                detail = String(localized: "Your Max Bolus or Max Carbs doesn't allow even one tablet and its bolus.")
            }
            return Check(
                id: "tablets",
                title: String(localized: "Tablets within your limits"),
                detail: detail,
                state: fits ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "Tablets within your limits"),
                    body: String(
                        localized: "The tablets' carbs stay within your Max Carbs, and their bolus within your Max Bolus, as Treatments holds them. These are app limits, not a rule from Trio docs."
                    ),
                    reading: limitsReading
                )
            )
        }

        /// Whether the carb ratio now, or in the hours a test of `length` begun now can run on
        /// (`CarbRatioTestEvaluator.coveredAtBegin`), is under the lowest the test can judge
        /// (`Config.minimumTestedCarbRatio`), as Begin refuses it (`SettingsTestBeginError.carbRatioUnderMinimum`).
        func carbRatioUnderMinimum(for length: TimeInterval) -> Bool {
            guard let ratio = settingsNow.carbRatio else { return false }
            let minimum = Config.minimumTestedCarbRatio
            let covered = CarbRatioTestEvaluator.coveredAtBegin(
                settingsNow.carbRatioEntries,
                startedAt: Date(),
                length: length
            ) ?? []
            return ratio < minimum || covered.contains { $0.value < minimum }
        }

        /// The length the carb ratio's minimum is checked over: the shortest one on the pages before How long, so a problem
        /// that picking 3 h clears doesn't hold up Next before that page can be reached; the one picked from How long on,
        /// so How long's Next and Begin wait for it.
        var minimumCheckLength: TimeInterval {
            let beforeLength: Set<CheckPage> = [.checks, .tablets]
            guard beforeLength.contains(shownCheckPage) else { return selectedLength }
            return Config.lengths.min() ?? selectedLength
        }

        /// Whether the carb ratio's minimum holds up the page shown (`minimumCheckLength`).
        var carbRatioUnderMinimum: Bool {
            carbRatioUnderMinimum(for: minimumCheckLength)
        }

        /// Shown only when the carb ratio is under the lowest the test can judge: Begin is held up, with the docs' minimum,
        /// and, when the shortest length stays clear of it, how to.
        private var carbRatioMinimumCheck: Check? {
            guard carbRatioUnderMinimum else { return nil }
            var sentence = SettingsTestBeginError.carbRatioUnderMinimum.message
            if let shortest = Config.lengths.min(), shortest < selectedLength, !carbRatioUnderMinimum(for: shortest) {
                sentence += " " + String(localized: "Watching for \(lengthText(shortest)) keeps the test clear of it.")
            }
            return Check(
                id: "carbRatioMinimum",
                title: String(localized: "Carb ratio of 2 g/U or more"),
                detail: sentence,
                state: .failed,
                info: SettingsTestInfo(
                    title: String(localized: "Carb ratio of 2 g/U or more"),
                    body: String(
                        localized: "The test judges your carb ratio in 1 g/U steps, the smallest change in Trio docs, so a ratio a step under yours must still be one Trio allows."
                    ),
                    reading: settingsNow.carbRatio.map {
                        String(
                            localized: "Your carb ratio is \(SettingsTestFormat.keepTogether(formatCarbRatio($0), unit: "g/U"))"
                        )
                    },
                    quote: Docs.minimumCarbRatio,
                    links: [Docs.testingMethodLink]
                )
            )
        }

        /// "Max Bolus 10 U · Max Carbs 250 g", once both are read.
        var limitsReading: String? {
            guard let maxBolus = settingsNow.maxBolus, let maxCarbs = settingsNow.maxCarbs else { return nil }
            let bolus = SettingsTestFormat.keepTogether(formatUnits(maxBolus), unit: "U")
            let carbs = SettingsTestFormat.keepTogether(formatGrams(maxCarbs), unit: "g")
            return String(localized: "Max Bolus \(bolus) · Max Carbs \(carbs)")
        }

        /// The docs test with "Zero or minimal COB from previous meals", a docs rule, so carbs on board at or over the
        /// test's line hold up Begin (`CarbRatioTestEvaluator.cobBlocks`). Nil while Trio hasn't read them recently, or
        /// there is no line for want of tablets (`cobUnreadCheck` then informs).
        private var cobCheck: Check? {
            guard let cob = currentCOB, let line = checkCOBLine else { return nil }
            let blocks = CarbRatioTestEvaluator.cobBlocks(cob: cob, line: line)
            let grams = formatGrams(CarbRatioTestEvaluator.shownGrams(cob))
            let lineText = SettingsTestFormat.keepTogether(formatGrams(line), unit: "g")
            return Check(
                id: "cob",
                title: String(localized: "Minimal carbs on board"),
                detail: blocks
                    ? String(localized: "\(grams) g on board, at or over the test's \(lineText). Begin once it has come down")
                    : nil,
                state: blocks ? .failed : .passed,
                info: cobInfo
            )
        }

        /// Shown while none of Trio's determinations in the last 12 minutes says how many carbs are on board, or there is
        /// no line to hold them against. It doesn't hold up Begin; the Dose step waits for a read under the line.
        private var cobUnreadCheck: Check? {
            guard currentCOB == nil || checkCOBLine == nil else { return nil }
            let value = currentCOB.map { "\(formatGrams(CarbRatioTestEvaluator.shownGrams($0))) g" }
                ?? String(localized: "Not read yet")
            return Check(id: "cobUnread", title: String(localized: "Carbs on board"), value: value, state: .info, info: cobInfo)
        }

        private var cobInfo: SettingsTestInfo {
            let reading = checkCOBLine.map { line in
                String(
                    localized: "For these tablets the line is \(SettingsTestFormat.keepTogether(formatGrams(line), unit: "g"))"
                )
            }
            return SettingsTestInfo(
                title: String(localized: "Minimal carbs on board"),
                body: String(
                    localized: "The carbs Trio still counts as absorbing from an earlier meal raise glucose on top of the tablets, so the test would count them against your carb ratio. At or over what a \(stepText) change of your carb ratio, the smallest change in Trio docs, covers for these tablets, the test waits for them to come down."
                ),
                reading: reading,
                quote: Docs.minimalCOB,
                links: [Docs.testingMethodLink]
            )
        }

        /// Shown only when insulin on board is more than the test's whole dose: Begin waits until it has come down.
        private var iobBlockCheck: Check? {
            guard iobDecision == .blocked, let dose = checkDose, let iob = currentIOB else { return nil }
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

        // MARK: Rows that inform

        /// The average of the last 3 readings, the glucose the result is judged from at the bolus. Without a recent reading
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
            let target = settingsNow.target.map {
                String(
                    localized: "Your target is \(SettingsTestFormat.keepTogether(formatTarget($0), unit: glucoseUnits.rawValue))"
                )
            }
            return Check(
                id: "glucose",
                title: String(localized: "Glucose now"),
                value: value,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Glucose now"),
                    body: String(
                        localized: "The average of your last 3 CGM readings. The test judges where glucose ends against where it was at your bolus, so starting near your target leaves room either way. Without a recent reading, this shows your newest one and how old it is. It's here for you to judge and doesn't hold up the start."
                    ),
                    reading: target,
                    quote: "\(Docs.startInRange)\n\(Docs.noRecentExercise)",
                    links: [Docs.testingMethodLink]
                )
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
                        localized: "The arrow is your CGM's own. The Dose step waits for it to be flat before the bolus. It doesn't hold up the start."
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
            let reading = checkDose.flatMap { dose in
                checkIOBLine.map { line in
                    let doseText = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
                    return String(localized: "The test's dose is \(doseText), so its line is \(lineText(line))")
                }
            }
            return SettingsTestInfo(
                title: String(localized: "Insulin on board"),
                body: String(
                    localized: "Insulin still working from an earlier dose or SMB adds to the bolus the test measures, and negative insulin on board, basal Trio held back, takes from it. More than what a \(stepText) change of your carb ratio, the smallest change in Trio docs, makes in the test's dose can sway the result, so you choose whether the test waits for it or counts it. More than the whole dose holds up the start."
                ),
                reading: reading,
                quote: "\(Docs.minimalIOB)\n\(Docs.smallChanges)",
                links: [Docs.testingMethodLink, Docs.bestPracticesLink]
            )
        }

        /// What the newest ISF test found. A warning only, never a block (round 7 Q4), with the triangle when it didn't
        /// look accurate on an unchanged ISF schedule.
        private var isfCheck: Check {
            let ready: Bool
            if case .ready = isfGate { ready = true } else { ready = false }
            return Check(
                id: "isf",
                title: String(localized: "ISF test"),
                value: isfGate.text(),
                state: ready ? .info : .warning,
                info: SettingsTestInfo(
                    title: String(localized: "ISF test"),
                    body: String(
                        localized: "The test turns where glucose ends into insulin with your ISF, so an ISF that's off moves the result. With your ISF tested first, the carb ratio is the one thing the test measures. It's here for you to judge and doesn't hold up the start."
                    ),
                    quote: Docs.crOrISF,
                    links: [ISFTest.Docs.testingMethodLink, Docs.testingMethodLink]
                )
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
        /// (`SettingsTestPageFlow.shown`), so the insulin on board page that stops applying hands over to How long. A page
        /// before it that starts to apply and hasn't been shown comes first: insulin on board going over the line while
        /// Ready shows brings up its page, so Begin can't go without the choice.
        var shownCheckPage: CheckPage {
            SettingsTestPageFlow.shown(checkPage, in: checkPages, order: CheckPage.allCases, seen: seenCheckPages)
        }

        /// "2 of 5", for the page's heading.
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

        /// One line of the Ready page's summary.
        struct SummaryRow: Equatable {
            let title: String
            let value: String
        }

        /// The Ready page's summary of the picks: the tablets and their grams, the bolus for them, how long to watch, and
        /// how insulin on board is handled when there was a choice to make.
        var readySummary: [SummaryRow] {
            var rows: [SummaryRow] = []
            if let count = tabletCount {
                let grams = SettingsTestFormat.keepTogether(formatGrams(tabletCarbs), unit: "g")
                rows.append(SummaryRow(
                    title: String(localized: "Tablets"),
                    value: String(localized: "\(count) \(selectedBrand.displayName) · \(grams)")
                ))
            }
            if let dose = checkDose {
                rows.append(SummaryRow(
                    title: String(localized: "Bolus"),
                    value: SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
                ))
            }
            rows.append(SummaryRow(
                title: String(localized: "Watch for"),
                value: String(localized: "\(lengthText(selectedLength)) after the bolus")
            ))
            if case .choice = iobDecision {
                rows.append(SummaryRow(
                    title: String(localized: "Insulin on board"),
                    value: iobChoice == .count ? String(localized: "Count It") : String(localized: "Wait for It")
                ))
            }
            return rows
        }

        /// Back: the page before the one shown, the insulin on board page skipped when it doesn't apply.
        func previousCheckPage() {
            guard let previous = SettingsTestPageFlow.page(before: shownCheckPage, in: checkPages) else { return }
            checkPage = previous
        }

        /// A page came up on screen (the Check step calls it as each page appears): it counts as shown from now on, and
        /// it is the page the user is on, so one brought up behind Ready stays until Next. Any other page closes a Begin
        /// confirmation left open, which then doesn't come back by itself with Ready.
        func checkPageAppeared(_ page: CheckPage) {
            seenCheckPages.insert(page)
            if checkPage != page {
                checkPage = page
            }
            if page != .ready {
                showStartConfirmation = false
            }
        }

        /// Whether Begin may go: Ready shows and, when insulin on board is over the line, its page has come up this pass,
        /// so its question was asked.
        var pagesAllowBegin: Bool {
            guard shownCheckPage == .ready else { return false }
            return !checkPages.contains(.iob) || seenCheckPages.contains(.iob)
        }

        /// Cancel, Done, or a test cleared elsewhere: the next start begins on the checks, with no page shown yet, on the
        /// docs' way.
        private func startOver() {
            iobChoice = .wait
            checkPage = .checks
            seenCheckPages = [.checks]
            showStartConfirmation = false
        }

        // MARK: - Dose

        /// The carb ratio and ISF the Dose step works the dose out with: those in force now, from the schedules Begin saved
        /// (`CarbRatioTestEvaluator.doseSettings`). Nil without a test.
        var doseSettings: (carbRatio: Decimal, isf: Decimal)? {
            test.map { CarbRatioTestEvaluator.doseSettings(of: $0, at: Date()) }
        }

        /// The pump's bolus increment: the pump can't give less, so a counted dose under it is none. The one Begin saved,
        /// which the running check and the verdict judge the bolus by; the live one before a test.
        private var bolusIncrement: Decimal {
            if let test { return test.bolusIncrement }
            let manager: SettingsManager? = settingsManager
            return manager?.preferences.bolusIncrement ?? 0
        }

        /// The dose the Dose step shows (`CarbRatioTestEvaluator.doseShown`): the docs' dose for the tablets with the carb
        /// ratio in force now, or, with Count It, less the insulin on board. Nil without a test, and when none is left.
        var docsDose: Decimal? {
            test.flatMap { CarbRatioTestEvaluator.doseShown(of: $0, doseInputs) }
        }

        /// The docs' dose before insulin on board is taken off, for the formula card of a test that counts it.
        var formulaDose: Decimal? {
            guard let test, let settings = doseSettings else { return nil }
            return CarbRatioTestEvaluator.dose(carbs: test.tabletCarbs, carbRatio: settings.carbRatio)
        }

        /// Whether the docs' dose before insulin on board follows "≈": carbs ÷ CR with more than 2 decimals.
        var formulaDoseIsApproximate: Bool {
            guard let test, let settings = doseSettings, let shown = formulaDose,
                  let exact = CarbRatioTestEvaluator.unroundedDose(carbs: test.tabletCarbs, carbRatio: settings.carbRatio)
            else { return false }
            return exact != shown
        }

        /// Whether the dose shown follows "≈": rounded to 2 decimals.
        var docsDoseIsApproximate: Bool {
            guard let test, let settings = doseSettings, let shown = docsDose else { return false }
            let exact = test.iobHandling == .count
                ? doseIOB.flatMap {
                    CarbRatioTestEvaluator.unroundedCountedDose(
                        carbs: test.tabletCarbs,
                        carbRatio: settings.carbRatio,
                        iob: $0,
                        increment: bolusIncrement
                    )
                }
                : CarbRatioTestEvaluator.unroundedDose(carbs: test.tabletCarbs, carbRatio: settings.carbRatio)
            return exact.map { $0 != shown } ?? false
        }

        /// Whether the Dose step takes insulin on board off the docs' dose: in a test that counts it.
        var dosesCountIOB: Bool {
            test?.iobHandling == .count
        }

        /// Why the Dose step doesn't offer the dose, for it to say. Nil when it does. Without a test there are no settings.
        var noDoseReason: CarbRatioTestNoDose? {
            guard let test else { return .noSettings }
            return CarbRatioTestEvaluator.noDoseReason(of: test, doseInputs)
        }

        /// Whether the Dose step offers the dose (`CarbRatioTestEvaluator.canDose`).
        var canDose: Bool {
            test.map { CarbRatioTestEvaluator.canDose(of: $0, doseInputs) } ?? false
        }

        /// With the tablets' carbs logged in a test that counts insulin on board Trio hasn't read: no dose can be shown,
        /// since it would leave the insulin on board in, but Treatments still opens for the bolus, with nothing filled in,
        /// where Trio's calculator takes it off.
        var countedDoseAwaitsIOB: Bool {
            test?.carbsLoggedAwaitingBolus == true && dosesCountIOB && noDoseReason == .iobUnread
        }

        /// What the Dose step's card says with the tablets' carbs logged and the bolus awaited: the dose due, or, with Count
        /// It and insulin on board unread (`countedDoseAwaitsIOB`), the bolus without a dose, which Trio's calculator works
        /// out; then the minutes left. Nil while no dose is due (`noDoseReason`), when the step's own card says what it
        /// waits for, and the time up (its sentence says the test is ending). Never the formula's dose for a counted one.
        var carbsLoggedCard: (headline: String, detail: String)? {
            guard let test, test.carbsLoggedAwaitingBolus, noDoseReason == nil || countedDoseAwaitsIOB else { return nil }
            let headline: String
            if noDoseReason == nil, let dose = docsDose {
                let units = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
                headline = String(localized: "The tablets' carbs are logged. Give the bolus now: \(units).")
            } else {
                headline = String(localized: "The tablets' carbs are logged. Give the bolus now.")
            }
            let minutes = test.minutesLeftForBolus(at: Date()) ?? 0
            let pairing = Int(Config.mealPairing / 60)
            let time = test.bolusDeadline?.formatted(date: .omitted, time: .shortened) ?? ""
            return (
                headline,
                String(
                    localized: "\(minutes) of \(pairing) minutes left, until \(time). Enter only the bolus in Treatments: the carbs are in. Then take the tablets."
                )
            )
        }

        /// Whether Open Treatments opens: while the step offers the dose, and with the tablets' carbs logged in a test
        /// whose counted dose waits for insulin on board (`countedDoseAwaitsIOB`). Never once the time for the bolus is up.
        var canOpenTreatments: Bool {
            canDose || countedDoseAwaitsIOB
        }

        /// Why Open Treatments is off, in the words the Dose step shows for it. Nil while it is on.
        var doseHoldText: String? {
            guard !canOpenTreatments else { return nil }
            return (noDoseReason ?? .noSettings).sentence
        }

        /// The line insulin on board must be under for the dose shown, in a test that doesn't count it, from the carb
        /// ratio now (`CarbRatioTestEvaluator.iobLine`). Nil without a dose, and in a test that counts insulin on board.
        var doseIOBLine: Decimal? {
            guard !dosesCountIOB, let dose = formulaDose, let settings = doseSettings else { return nil }
            return CarbRatioTestEvaluator.iobLine(dose: dose, carbRatio: settings.carbRatio)
        }

        /// The Dose step's line while insulin on board is over the line for the dose: how much there is against the
        /// line, or that Trio hasn't read it.
        var iobWaitText: String? {
            guard let dose = formulaDose else { return nil }
            let doseText = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
            guard let iob = currentIOB, let line = doseIOBLine else {
                return CarbRatioTestNoDose.iobUnread.sentence
            }
            let iobText = SettingsTestFormat.keepTogether(formatSignedUnits(iob), unit: "U")
            return iob < 0
                ? String(
                    localized: "Your insulin on board is \(iobText), more than \(lineText(line)) from zero: what a \(stepText) change of your carb ratio, the smallest change in Trio docs, makes in this dose of \(doseText)."
                )
                : String(
                    localized: "Your insulin on board is \(iobText), over \(lineText(line)): what a \(stepText) change of your carb ratio, the smallest change in Trio docs, makes in this dose of \(doseText)."
                )
        }

        /// The time the bolus must come by, worded as the app's limit it is, not a treatment rule: the dose deadline, which
        /// runs from the end of settling, or, with the tablets' carbs logged, the meal's own time if that is sooner. A
        /// clock time only, since the minutes run from settling's end, not from Begin.
        var doseDeadlineText: String? {
            guard let test else { return nil }
            let deadline = test.bolusDeadline.map { min($0, test.doseDeadline) } ?? test.doseDeadline
            let time = deadline.formatted(date: .omitted, time: .shortened)
            return String(localized: "The test needs your bolus by \(time).")
        }

        /// The Recommended Bolus Percentage as a fraction, e.g. 0.8.
        private var recommendedBolusFraction: Decimal {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.overrideFactor ?? 1
        }

        /// About what Trio's bolus calculator will suggest for the docs' dose: the dose times the Recommended Bolus
        /// Percentage (`ISFTestEvaluator.suggestion`). Trio also adds a correction and takes insulin on board off, so it is
        /// only about it.
        var trioSuggestion: Decimal? {
            docsDose.map { ISFTestEvaluator.suggestion(for: $0, percentage: recommendedBolusFraction) }
        }

        /// The insulin on board the units judged count with the bolus: with Count It, the counted dose's; none otherwise,
        /// where the bolus alone is judged (`CarbRatioTestEvaluator.bolusOffFormula`).
        private var suggestionIOB: Decimal {
            dosesCountIOB ? (doseIOB ?? 0) : 0
        }

        /// Whether Trio's `suggestion`, with the insulin on board the units judged count, sits inside the range the test
        /// accepts by at least a pump increment, which is the doses a docs step either side of the formula's gives
        /// (`CarbRatioTestEvaluator.suggestionInRange`): only then may the note say "Either is fine". False without a test.
        func suggestionInRange(_ suggestion: Decimal) -> Bool {
            guard let test, let settings = doseSettings else { return false }
            return CarbRatioTestEvaluator.suggestionInRange(
                suggestion,
                iob: suggestionIOB,
                carbs: test.tabletCarbs,
                carbRatio: settings.carbRatio,
                increment: bolusIncrement
            )
        }

        /// The boluses the test can judge, the units given less the insulin on board they count, e.g. "3.60–4.45 U", for the
        /// note's info sheet. Nil without a test, and for a range with no top.
        var bolusRangeText: String? {
            guard let test, let settings = doseSettings,
                  let range = CarbRatioTestEvaluator.bolusRange(
                      carbs: test.tabletCarbs,
                      carbRatio: settings.carbRatio,
                      increment: bolusIncrement
                  ),
                  let highest = range.highest
            else { return nil }
            let low = formatUnits(max(0, range.lowest - suggestionIOB))
            let high = formatUnits(max(0, highest - suggestionIOB))
            return SettingsTestFormat.keepTogether("\(low)–\(high)", unit: "U")
        }

        /// The Recommended Bolus Percentage as a whole percent, e.g. 80.
        var bolusPercent: Int {
            NSDecimalNumber(decimal: rounded(recommendedBolusFraction * 100, scale: 0, roundingMode: .plain)).intValue
        }

        /// What the Dose step's yellow note and its info sheet say about Trio's `suggestion` beside the formula's `dose`,
        /// by whether the Recommended Bolus Percentage makes it less than, the same as, or more than the dose, as the ISF
        /// test's note does. Each amount stays on one line with its "U".
        func suggestionNote(suggestion: Decimal, dose: Decimal) -> (note: String, info: String) {
            let suggested = SettingsTestFormat.keepTogether(formatUnits(suggestion), unit: "U")
            let docs = SettingsTestFormat.keepTogether(formatUnits(dose), unit: "U")
            let percent = bolusPercent
            let extras = String(
                localized: "It also adds a correction for your glucose against your target and takes off insulin on board, so its number can differ a little."
            )
            let perUnit = String(
                localized: "Tap Trio's suggestion or enter the formula's dose: the test judges your carb ratio by the units you actually give."
            )
            // Too far from the formula's for the result to rest on the carb ratio: the formula's dose is the one to enter.
            guard suggestionInRange(suggestion) else {
                let range = bolusRangeText.map { String(localized: " For these tablets that's \($0).") } ?? ""
                return (
                    String(
                        localized: "Enter \(docs). Trio's suggestion of about \(suggested) is too far from the formula's dose for the test to judge."
                    ),
                    String(
                        localized: "The test judges your carb ratio in 1 g/U steps, the smallest change in Trio docs, so the bolus has to be within the doses a step either way gives."
                    ) + range + " " + String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%), which falls outside that, so enter \(docs) in the bolus field."
                    )
                )
            }
            switch ISFTestEvaluator.suggestionComparison(percent: percent) {
            case .less:
                return (
                    String(
                        localized: "Trio will suggest about \(suggested). That's \(percent)% of the formula's \(docs). Either is fine: the result is worked out from what you give."
                    ),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%). SMBs normally give the rest, but they're off during the test."
                    ) + " " + extras + " " + perUnit
                )
            case .same:
                return (
                    String(localized: "Trio will suggest about the formula's \(docs)."),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%), so the two match."
                    ) + " " + extras + " " + perUnit
                )
            case .more:
                // More than the docs' dose can bring on a low the carb ratio doesn't explain, so the docs' dose is the one
                // to give.
                return (
                    String(
                        localized: "Trio will suggest about \(suggested). That's \(percent)% of the formula's \(docs). Enter the formula's \(docs) instead of tapping Trio's suggestion."
                    ),
                    String(
                        localized: "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (\(percent)%), so its suggestion is more than the formula's dose."
                    ) + " " + extras + " " +
                        String(localized: "Enter the formula's \(docs) instead of tapping Trio's suggestion.")
                )
            }
        }

        /// Whether the CGM shows glucose leveled off: a flat arrow, or none for a recent reading.
        var glucoseIsLevel: Bool {
            ISFTestEvaluator.glucoseIsLevel(doseInputs.isfInputs)
        }

        // MARK: - Waiting

        /// Readings since the bolus, oldest first. One at the same moment as the saved bolus counts as at it.
        var runningReadings: [BasalTestReading] {
            guard let bolusAt = test?.bolusAt else { return [] }
            return ISFTestEvaluator.readings(recentReadings, since: bolusAt).sorted { $0.date < $1.date }
        }

        /// While waiting with the tablets' carbs not logged yet: when they must be logged by. Nil once they are, and on
        /// any other step.
        /// While waiting with the tablets' carbs not logged yet: the whole minutes left to log them, rounded up, never below
        /// 0. Nil once they are logged.
        func carbsMinutesLeft(at now: Date) -> Int? {
            guard let until = carbsAwaitedUntil else { return nil }
            return Int((max(0, until.timeIntervalSince(now)) / 60).rounded(.up))
        }

        var carbsAwaitedUntil: Date? {
            guard let test, test.phase == .waiting, test.carbs == nil else { return nil }
            return test.carbsDeadline
        }

        // MARK: - Result

        /// The finished test's result, worked out again from what it saved, when it gives the verdict the headline shows
        /// (`CarbRatioTestEvaluator.matchingEvaluation`).
        var evaluation: CarbRatioTestEvaluator.Evaluation? {
            test.flatMap { CarbRatioTestEvaluator.matchingEvaluation(of: $0) }
        }

        /// The whole end readings the result calls accurate, which the chart shades. Nil for a result not judged on where
        /// glucose ended, and when the band has no top (a carb ratio at or under the docs' step).
        var resultBand: ClosedRange<Int>? {
            guard let band = test.flatMap({ CarbRatioTestEvaluator.resultBand(of: $0) }), let highest = band.highest else {
                return nil
            }
            return band.lowest ... highest
        }

        /// The last part of the chosen length, where the chart shades the band.
        var resultBandTimes: ClosedRange<Date>? {
            guard let end = test?.plannedEnd else { return nil }
            return end.addingTimeInterval(-Config.expectedEndShading) ... end
        }

        /// Why the finished test says nothing about the carb ratio. Nil when it does.
        var noVerdict: CarbRatioTestNoVerdict? {
            test.flatMap { CarbRatioTestEvaluator.noVerdict(for: $0) }
        }

        /// Where glucose would end if the carb ratio were right, start + ISF × (carbs ÷ CR − units), in mg/dL, when the
        /// start glucose isn't among the readings the result calls accurate: the units that acted weren't the formula's
        /// dose for the carbs logged, so ending where it started isn't what an accurate ratio gives. Nil otherwise.
        var expectedEndAwayFromStart: Decimal? {
            guard let test, evaluation?.shownRatio != nil, let band = CarbRatioTestEvaluator.resultBand(of: test),
                  let start = test.startGlucose, !band.contains(start),
                  let carbs = CarbRatioTestEvaluator.judgedCarbs(of: test),
                  let units = CarbRatioTestEvaluator.judgedUnits(of: test), test.carbRatio > 0
            else { return nil }
            return Decimal(start) + test.isf * (carbs / test.carbRatio - units)
        }

        /// The Result's line beside the band: the insulin Trio reported still on board at the end and roughly how far it
        /// would still move glucose (`CarbRatioTestEvaluator.stillToComeOff`). The band is on the units that acted, so it
        /// sits that much above where glucose would settle. Nil without a band, and with none on board.
        var stillToComeOffLine: String? {
            guard resultBand != nil, let test, let iob = test.iobAtEnd,
                  let shift = CarbRatioTestEvaluator.stillToComeOff(iobAtEnd: iob, isf: test.isf), shift != 0
            else { return nil }
            let units = SettingsTestFormat.keepTogether(formatUnits(abs(iob)), unit: "U")
            let amount = formatWithUnits(abs(shift))
            return iob > 0
                ? String(localized: "\(units) was still on board at the end: about \(amount) still to come off.")
                : String(localized: "Trio had held back \(units) of basal at the end: about \(amount) still to come back up.")
        }

        /// The Result's tablets card: the tablets and their grams, then what was logged with the bolus. That the result
        /// uses the tablets' grams is said only when it does: grams logged within the 1 g rule (`carbsDiffer`) of a test
        /// with a verdict. A test the grams made invalid, or one with no verdict, says only what was logged. Nil without a
        /// test.
        var resultTabletsText: String? {
            guard let test else { return nil }
            let brand = test.brand?.displayName ?? test.tabletBrand
            let grams = SettingsTestFormat.keepTogether(formatGrams(test.tabletCarbs), unit: "g")
            let tablets = test.tabletCount == 1
                ? String(localized: "1 tablet of \(brand) (\(grams))")
                : String(localized: "\(test.tabletCount) tablets of \(brand) (\(grams))")
            guard let carbs = test.carbs else {
                return String(localized: "\(tablets). Their carbs weren't logged with the bolus.")
            }
            let loggedGrams = SettingsTestFormat.keepTogether(formatGrams(carbs), unit: "g")
            if carbs == test.tabletCarbs {
                return String(localized: "\(tablets), logged as \(loggedGrams) with the bolus.")
            }
            let judgedOnPlanned = !CarbRatioTestEvaluator.carbsDiffer(logged: carbs, planned: test.tabletCarbs)
                && test.outcome?.isConclusive == true
            guard judgedOnPlanned else {
                return String(localized: "\(tablets). \(loggedGrams) logged with the bolus.")
            }
            // Within a gram, the entry field's rounding: the result is judged on what was eaten.
            return String(localized: "\(tablets). \(loggedGrams) logged with the bolus; the result uses the tablets' \(grams).")
        }

        /// Whether the test ended on Trio's suspend on its forecast with glucose still above where it started, which isn't
        /// a low (`CarbRatioTestNoVerdict.forecastSuspend`).
        var isForecastSuspend: Bool {
            test?.endReason == .low && noVerdict == .forecastSuspend
        }

        /// Whether the Result shows the low card, "Treat the low as usual": only for a low that is one.
        var showsLowCard: Bool {
            test?.endReason == .low && !isForecastSuspend
        }

        /// "Trio suspended insulin for a low at 5:58 PM", for a low that is one. Nil otherwise.
        var lowSuspendObservation: String? {
            guard showsLowCard, let suspendedAt = test?.endedAt else { return nil }
            return String(
                localized: "Trio suspended insulin for a low at \(suspendedAt.formatted(date: .omitted, time: .shortened))"
            )
        }

        /// The end of the chart caption, for why the test ended early.
        var endedEarlyCaption: String {
            switch test?.endReason {
            case .low:
                return isForecastSuspend
                    ? String(localized: ". Ended early: Trio suspended insulin on its forecast.")
                    : String(localized: ". Ended early: Trio suspended insulin for a low.")
            case .endedEarly: return String(localized: ". You ended it early.")
            case .interrupted: return String(localized: ". Ended early: it was interrupted.")
            case .completed,
                 nil,
                 .noBolus,
                 .unchecked: return ""
            }
        }

        /// The insulin on board at the bolus the Result shows beside it, signed: in a test that counts it, whatever it
        /// was; otherwise when it shows as more than 0.00 U. Nil when there is none to show.
        var shownIOBAtBolus: Decimal? {
            guard let test, let iob = test.iobAtBolus else { return nil }
            return test.iobHandling == .count || ISFTestEvaluator.shownSize(of: iob) != 0 ? iob : nil
        }

        /// "4.00 U", or "4.00 U plus 0.30 U on board" in a test with insulin on board to show. Nil without units given.
        var unitsGivenText: String? {
            guard let test, CarbRatioTestEvaluator.givenUnits(of: test) != nil, let bolus = test.bolusUnits else { return nil }
            let bolusText = SettingsTestFormat.keepTogether(formatUnits(bolus), unit: "U")
            guard let iob = shownIOBAtBolus else { return bolusText }
            let iobText = SettingsTestFormat.keepTogether(formatUnits(abs(iob)), unit: "U")
            return iob < 0
                ? String(localized: "\(bolusText) less \(iobText) Trio held back")
                : String(localized: "\(bolusText) plus \(iobText) on board")
        }

        /// Whether a result says to change the carb ratio, so the Result offers Open Carb Ratios.
        var offersCarbRatios: Bool {
            test?.outcome == .tooHigh || test?.outcome == .tooLow
        }

        /// Whether Basal Testing is still on with no test running it, so the Result says so.
        var basalTestingLeftOn: Bool {
            SettingsTestModeRule.basalTestingLeftOn(mode: currentMode, activeSessionID: testService.activeSession?.id)
        }

        // MARK: - Subscription

        override func subscribe() {
            if let runner = runner ?? testService.carbRatioRunner {
                follow(runner)
            } else {
                warning(
                    .settings,
                    "CarbRatioTest: the settings test service has no carb ratio runner, so the screen can't run a test"
                )
            }
            if let brand = test?.brand {
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

            // The tablets' carbs, logged with the bolus, are what the Wait step looks for.
            CoreDataStack.shared.entityChangePublisher
                .receive(on: DispatchQueue.main)
                .filteredByEntityName("CarbEntryStored")
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            // Right away, so the first frame doesn't show "No other test running" as passed, or no ISF test.
            showSession(testService.activeSession, lastEnd: testService.lastEnd())
            isfGate = readISFGate()
            testService.sessionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in self?.showSession(session, lastEnd: self?.testService.lastEnd()) }
                .store(in: &dataSubscriptions)

            Task { await refresh() }
        }

        /// Shows the runner's state now, so the first frame is the test's step, and each change it publishes, on the main
        /// queue.
        func follow(_ runner: CarbRatioTestRunning) {
            self.runner = runner
            apply(runner.state)
            runner.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in self?.apply(state) }
                .store(in: &dataSubscriptions)
        }

        /// Shows the service's session: the one running, and the one it last ended on its own.
        func showSession(_ session: SettingsTestSession?, lastEnd: SettingsTestEnd?) {
            activeSessionKind = session?.kind
            serviceSession = (activeID: session?.id, lastEndID: lastEnd?.sessionID)
        }

        /// Whether the test is ending, so its step takes none of its actions (`SettingsTestModeRule.isEnding`).
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
        func apply(_ runnerState: CarbRatioTestRunnerState) {
            // Gone, however it went (Cancel or Done here or elsewhere): the next start begins on the checks, on the docs'
            // way. Not a test this screen's own Begin published and took back, which failed: its pages stay.
            if test != nil, runnerState.test == nil, !beginInFlight {
                startOver()
            }
            test = runnerState.test
            settling = runnerState.settling?.decision
            settlingBoluses = runnerState.settling?.boluses ?? []
            settleReadings = runnerState.settling?.readingsAfterLoop
            settleTempBasalRunning = runnerState.settling?.tempBasalRunning ?? false
            settleIOB = runnerState.settling?.iob
            doseIOB = runnerState.doseIOB
        }

        /// What `refresh` reads for the Check and Dose steps, shown in one step on the main actor (`show`).
        struct ScreenData {
            /// Newest first.
            var readings: [BasalTestReading]
            var iob: Decimal?
            var cob: Decimal?
            var doseCOB: Decimal?
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
            doseCOB = data.doseCOB
            hasActiveAdjustment = data.hasActiveAdjustment
            hasPumpSetTempBasal = data.hasPumpSetTempBasal
            pumpDelivery = data.pumpDelivery
            hasDevices = data.hasDevices
            trendDirection = data.trendDirection
        }

        /// Shows the settings `refresh` read.
        func show(_ settings: ScreenSettings) {
            settingsNow = settings
        }

        /// Pulls fresh data for the screen, then has the runner check a running test. Refreshes overlap and can finish out
        /// of order, so one that finishes after a newer one has shown its reads shows nothing: an older snapshot never
        /// replaces a newer one.
        func refresh() async {
            let number = await MainActor.run { () -> Int in
                refreshesBegun += 1
                return refreshesBegun
            }
            let reads = self.reads
            let now = Date()
            let settings = ScreenSettings(
                carbRatio: reads.carbRatio(at: now),
                isf: reads.isf(at: now),
                target: reads.target(at: now),
                maxBolus: reads.maxBolus(),
                maxCarbs: reads.maxCarbs(),
                carbRatioEntries: reads.carbRatioEntries()
            )
            let gate = readISFGate()
            let windowStart = await MainActor.run { test?.bolusWindowStart }
            do {
                let readings = try await reads.fetchRecentGlucose(minutes: Self.recentReadingsMinutes)
                let iob = reads.currentIOB()
                // From a determination at most 12 minutes old; none, or a read that failed, is unread, not none.
                let cob = (try? await reads.currentCOB()) ?? nil
                let doseCOB = await reads.doseCOB(windowStart: windowStart)
                let adjustment = try await reads.hasActiveAdjustment()
                let data = ScreenData(
                    readings: readings,
                    iob: iob,
                    cob: cob,
                    doseCOB: doseCOB,
                    hasActiveAdjustment: adjustment,
                    hasPumpSetTempBasal: reads.hasPumpSetTempBasal(),
                    pumpDelivery: reads.pumpDelivery(),
                    hasDevices: reads.hasCgmAndPump(),
                    // The CGM's arrow on the newest of these readings, from the same row.
                    trendDirection: readings.first?.direction
                )
                await MainActor.run {
                    guard number > newestRefreshShown else { return }
                    newestRefreshShown = number
                    show(settings)
                    isfGate = gate
                    show(data)
                }
            } catch {
                await MainActor.run {
                    guard number > newestRefreshShown else { return }
                    newestRefreshShown = number
                    show(settings)
                    isfGate = gate
                    // Unread, not the last read: the Dose step waits for one rather than gate on an old value.
                    readIOB = nil
                    errorMessage = "Couldn't read your data: \(error.localizedDescription)"
                }
            }
            await runner?.check()
        }

        /// The newest ISF test against the ISF schedule now.
        private func readISFGate() -> SettingsTestSchedule.ISFGate {
            SettingsTestSchedule.isfGate(history: testService.history(for: .isf), current: reads.isfEntries())
        }

        // MARK: - Begin

        private var noRecentGlucoseMessage: String {
            String(localized: "Trio has no recent glucose reading. Wait for your CGM's next reading, then try again.")
        }

        func requestStart() {
            guard readyToStart, pagesAllowBegin else { return }
            guard doseGlucose != nil else {
                errorMessage = noRecentGlucoseMessage
                return
            }
            guard let isf = settingsNow.isf, isf > 0, settingsNow.target != nil else {
                errorMessage = SettingsTestBeginError.settingsUnreadable.message
                return
            }
            showStartConfirmation = true
        }

        /// What Begin starts the test with, from what the Check screen shows. Nil without a recent glucose or tablets, and
        /// away from Ready or before the insulin on board question was asked when it applies (`pagesAllowBegin`). The
        /// insulin on board choice goes only when its page showed (`checkPages`): a pick kept from an earlier pass isn't one.
        var beginRequest: CarbRatioTestBegin? {
            guard pagesAllowBegin, let glucose = doseGlucose, let count = tabletCount else { return nil }
            return CarbRatioTestBegin(
                brand: selectedBrand,
                count: count,
                length: selectedLength,
                glucose: glucose,
                iob: currentIOB,
                iobChoice: checkPages.contains(.iob) ? iobChoice : nil
            )
        }

        /// Begin: the runner saves the test, starts its session and switches to Basal Testing. Only when every check
        /// passes, Basal Testing being off among them, from Ready with the insulin on board question asked when it
        /// applies (`pagesAllowBegin`), so a confirmation left open while another page came up does nothing, and with a
        /// glucose to start from: none is made up.
        @MainActor func confirmStart() {
            showStartConfirmation = false
            guard readyToStart, pagesAllowBegin else { return }
            // The reading may have grown too old while the confirmation was up.
            guard let begin = beginRequest else {
                errorMessage = noRecentGlucoseMessage
                return
            }
            beginInFlight = true
            Task { @MainActor in
                if let error = await runner?.begin(begin) {
                    errorMessage = error.message
                }
                // After what the runner published during Begin, which reaches `apply` through the main queue.
                DispatchQueue.main.async { [weak self] in self?.beginInFlight = false }
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
            guard let test else { return false }
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
        /// still running: the step offers only Cancel. The runner ends the test with the same sentence.
        var settleNoLoopMessage: String? {
            settling.flatMap(CarbRatioTestEvaluator.settlingDeadEnd)
        }

        /// The question once the settling allowance is up with insulin on board still over the line, or still unread.
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
                : String(
                    localized: "Your insulin on board is still \(iob), over \(lineText(line)). Count it and go on, or cancel?"
                )
        }

        // MARK: - Dose

        /// Trio's own Treatments screen gives the bolus, so its checks all apply; the tablets' carbs are filled in on it.
        /// A tap the step drew before its gate shut (a reading that aged since, say) says why (`doseHoldText`).
        @MainActor func openTreatments() {
            guard !isEnding else { return }
            guard canOpenTreatments, let test else {
                errorMessage = doseHoldText
                return
            }
            // Logged ahead of the bolus, the carbs aren't filled in again: the sheet is for the bolus alone.
            if !test.carbsLoggedAwaitingBolus {
                prefill.prepare(carbs: test.tabletCarbs)
            }
            sendToTreatments()
        }

        /// The Wait step's way to log the tablets' carbs after the bolus, with nothing filled in: Trio's Recommendation
        /// for them would suggest a second bolus, which ends the test. Only while they are awaited.
        @MainActor func openTreatmentsForCarbs() {
            guard !isEnding, let until = carbsAwaitedUntil, until > Date() else { return }
            sendToTreatments()
        }

        /// Opens Treatments. A screen opened from a notice comes back when Treatments closes (`treatmentsOpened`).
        @MainActor private func sendToTreatments() {
            if opener.wasOpenedFromNotice(.carbRatio) {
                opener.treatmentsOpened(from: .carbRatio)
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
            startOver()
            Task { await refresh() }
        }

        /// Done: clears a finished result so the user can start over, on the docs' way.
        @MainActor func acknowledgeResult() {
            runner?.acknowledgeResult()
            startOver()
            Task { await refresh() }
        }
    }
}
