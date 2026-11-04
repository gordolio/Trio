import Combine
import CoreData
import Foundation
import Observation
import SwiftUI

extension BasalTest {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        /// What runs the fast, in the service: the screen shows its state (`apply`) and passes the user's actions on. The
        /// service's (`subscribe`), or one a test sets.
        @ObservationIgnored var runner: BasalTestRunning?
        /// What `refresh` reads: the provider, or what a test sets.
        @ObservationIgnored var screenReads: BasalTestProvider?
        private var reads: BasalTestProvider { screenReads ?? provider }

        // MARK: - State

        /// The test in progress or just finished, as the runner saved it. `nil` while the user is still getting ready.
        private(set) var test: BasalTestState?

        /// Newest first, for the readiness checks.
        private(set) var recentReadings: [BasalTestReading] = []
        private(set) var currentIOB: Decimal = 0
        private(set) var currentCOB: Decimal = 0
        private(set) var lastCarb: Date?
        private(set) var hasActiveAdjustment = false
        private(set) var hasPumpSetTempBasal = false
        private(set) var hasDevices = true
        /// The CGM's own trend arrow for the newest reading.
        private(set) var trendDirection: BloodGlucose.Direction?
        /// The kind of settings test running, if any. Only one can run at a time.
        private(set) var activeSessionKind: SettingsTestKind?
        /// The session running and the one the service last ended on its own, as the service last said (`showSession`).
        /// Nil until the screen has read them.
        private(set) var serviceSession: (activeID: UUID?, lastEndID: UUID?)?
        /// What the SMB row reads. Nil until the first read.
        private(set) var fastingSource: FastingSource?
        /// The basal schedule now, for the hours the Check screen says the fast will cover.
        private(set) var basalSchedule: [SettingsTestScheduleEntry] = []

        /// The SMBs and carbs-on-board samples read for one screen: the past week on the Check screen, or the
        /// week before a finished test on the Result screen.
        struct FastingSource {
            /// The test they were read for. Nil for the Check screen.
            let testID: UUID?
            let smbs: [BasalTestSMB]
            let cob: [BasalTestCOBSample]
        }

        /// Hours the user picked for the fast.
        var selectedHours = 4

        var errorMessage: String?
        var showStartConfirmation = false
        var showStopOptions = false

        @ObservationIgnored private var dataSubscriptions = Set<AnyCancellable>()

        // MARK: - Units

        var glucoseUnits: GlucoseUnits {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.units ?? .mgdL
        }

        func format(_ mgdl: Int) -> String {
            mgdl.formatted(for: glucoseUnits)
        }

        /// "72 mg/dL", kept on one line where it sits in a sentence.
        func formatWithUnits(_ mgdl: Int) -> String {
            SettingsTestFormat.keepTogether(format(mgdl), unit: glucoseUnits.rawValue)
        }

        /// A change in glucose with its sign, e.g. "+22".
        func formatChange(_ mgdl: Int) -> String {
            let value = glucoseUnits == .mmolL ? Double(truncating: abs(mgdl).asMmolL as NSNumber) : Double(abs(mgdl))
            let text = glucoseUnits == .mmolL ? String(format: "%.1f", value) : "\(Int(value))"
            return (mgdl < 0 ? "-" : "+") + text
        }

        /// The ISF, stored in mg/dL per unit, in the user's units.
        func formatISF(_ isf: Decimal) -> String {
            isf.formattedISF(for: glucoseUnits)
        }

        /// A number with its sign, e.g. "+0.15", rounded toward zero like the share beside it, so neither is shown as
        /// more than it is. The sign follows the number as shown, so one that rounds to zero has none.
        func formatSigned(_ value: Decimal, fractionDigits: Int) -> String {
            let shown = BasalTestEvaluator.towardZero(value, scale: fractionDigits)
            let text = abs(shown).formatted(.number.precision(.fractionLength(fractionDigits)))
            return (shown > 0 ? "+" : shown < 0 ? "-" : "") + text
        }

        /// A share of the basal as a whole percent with its sign, e.g. "+18%". Rounded toward zero, so it never
        /// reads as the docs' step before it has reached it.
        func formatPercent(_ share: Decimal) -> String {
            let percent = BasalTestEvaluator.wholePercent(share)
            return (percent > 0 ? "+" : percent < 0 ? "-" : "") + abs(percent).formatted() + "%"
        }

        /// The docs' smallest basal change as a whole percent.
        var stepPercent: Int {
            NSDecimalNumber(decimal: Config.docsSmallestStep * 100).intValue
        }

        var currentMode: DosingMode {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.dosingMode ?? .open
        }

        // MARK: - Step

        var step: Step {
            switch test?.phase {
            case .running: return .fast
            case .finished: return .result
            case nil: return .check
            }
        }

        // MARK: - Readiness

        var currentGlucose: Int? { recentReadings.first?.glucose }

        /// The glucose the fast starts from: the mean of the newest 3 readings, the same mean its end is read by
        /// (`BasalTestEvaluator.endGlucose`). Nil without a reading 12 minutes old or newer, or with a CGM gap among them,
        /// which holds Start up: a CGM that isn't reading can't watch the fast.
        var startGlucose: Int? {
            BasalTestEvaluator.endGlucose(from: Array(recentReadings.prefix(3)), endingAt: Date())
        }

        var fastedLongEnough: Bool {
            guard let lastCarb else { return true }
            return Date().timeIntervalSince(lastCarb) >= Config.fastBeforeStart
        }

        var modeAvailable: Bool { currentMode != .basalTesting }

        /// The CGM's own arrow for the newest reading, if it gave one and the reading is recent.
        var trendArrow: String? {
            guard !readingIsStale, let direction = trendDirection else { return nil }
            switch direction {
            case .none,
                 .notComputable,
                 .rateOutOfRange: return nil
            default: return direction.symbol
            }
        }

        /// How much glucose changed over the last half hour, in mg/dL: the newest reading against the one nearest
        /// 30 minutes before it. Nil without a recent reading, or one to compare it with.
        var thirtyMinuteChange: Int? {
            guard !readingIsStale, let newest = recentReadings.first else { return nil }
            let target = newest.date.addingTimeInterval(-Config.trendWindow)
            func distance(_ reading: BasalTestReading) -> TimeInterval {
                abs(reading.date.timeIntervalSince(target))
            }
            guard let earlier = recentReadings.min(by: { distance($0) < distance($1) }),
                  distance(earlier) <= Config.trendTolerance
            else { return nil }
            return newest.glucose - earlier.glucose
        }

        struct Check: Identifiable {
            let id: String
            let title: String
            /// What a check that passes or fails says beyond its title. Nil when the title says it all.
            var detail: String?
            /// What a reading shows on its one line, e.g. "121 mg/dL".
            var value: String?
            let state: SettingsTestCheckState
            /// Why the row is there. Its info button opens it.
            let info: SettingsTestInfo
        }

        /// What has to be true before the fast starts: the docs' rule about food, and facts about the app.
        var blockingChecks: [Check] {
            [devicesCheck, foodCheck, adjustmentsCheck, pumpTempBasalCheck, modeCheck, otherTestCheck]
        }

        /// Readings that go with the docs' words but set no rule, so they never hold up the start.
        var informingChecks: [Check] {
            var rows = [glucoseCheck, trendCheck, iobCheck, cobCheck]
            if let smbCheck {
                rows.append(smbCheck)
            }
            return rows
        }

        var readyToStart: Bool {
            blockingChecks.allSatisfy { $0.state == .passed }
        }

        /// Shown one by one, because each says what to do.
        var failingChecks: [Check] { blockingChecks.filter { $0.state != .passed } }

        /// Folded into one line on the Check screen.
        var passingChecks: [Check] { blockingChecks.filter { $0.state == .passed } }

        /// Why Start can't be tapped yet, for the line above it: what the first check that fails says.
        var startBlocker: String? {
            guard let check = failingChecks.first else { return nil }
            return check.detail ?? check.title
        }

        /// The hours a fast started now would cover, and the basal schedule entries in them.
        var plannedWindow: (start: Date, end: Date, covered: [SettingsTestScheduleEntry]) {
            let start = Date()
            let duration = TimeInterval(selectedHours) * 3600
            let snapshot = BasalTestEvaluator.snapshot(of: basalSchedule, startingAt: start, for: duration)
            return (start, start.addingTimeInterval(duration), snapshot.covered ?? [])
        }

        /// Where Basal Testing suspends for a low, in mg/dL: its own line, or the user's low threshold if that is
        /// higher (`Preferences.clamped(for:)`).
        var lowThreshold: Int {
            NSDecimalNumber(decimal: max(userLowThreshold, Preferences.basalTestingThreshold)).intValue
        }

        /// Whether `lowThreshold` is the user's own setting, so the screen shows it in blue.
        var lowThresholdFromSettings: Bool {
            userLowThreshold > Preferences.basalTestingThreshold
        }

        private var userLowThreshold: Decimal {
            let manager: SettingsManager? = settingsManager
            return manager?.preferences.threshold_setting ?? 0
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
                        localized: "Trio needs your CGM to watch glucose and your pump to deliver your basal while the test runs."
                    )
                )
            )
        }

        private var foodCheck: Check {
            let detail: String
            if let lastCarb {
                let ago = Date().timeIntervalSince(lastCarb)
                // When it will clear, so the user doesn't have to work it out.
                let ready = lastCarb.addingTimeInterval(Config.fastBeforeStart).formatted(date: .omitted, time: .shortened)
                detail = fastedLongEnough
                    ? String(localized: "Last carbs \(SettingsTestFormat.duration(ago)) ago")
                    : String(localized: "Ready at \(ready) (2 h after your last carbs)")
            } else {
                detail = String(localized: "No carbs logged in the last 6 hours")
            }
            return Check(
                id: "fast",
                title: String(localized: "No food for 2 hours"),
                detail: detail,
                state: fastedLongEnough ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "No food for 2 hours"),
                    body: String(
                        localized: "The docs start a fast at least 2 hours after you last ate, so earlier food isn't still acting. Trio looks at the carbs you logged in the last 6 hours."
                    ),
                    quote: Docs.fastingRule,
                    links: [Docs.fastingTestsLink]
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
                        localized: "Basal Testing cancels a temp basal Trio set, but not one set on the pump itself. That one would keep running, so the fast wouldn't show what your basal rates do."
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
                        localized: "An override or a temp target changes how much insulin Trio gives, so the fast wouldn't show what your basal rates do on their own."
                    ),
                    quote: "\(Docs.overridesChangeSettings)\n\(Docs.tempTargetsChangeInsulin)",
                    links: [Docs.overridesLink, Docs.tempTargetsLink]
                )
            )
        }

        private var modeCheck: Check {
            Check(
                id: "mode",
                title: String(localized: "Starting from your usual mode"),
                detail: modeAvailable
                    ? String(localized: "\(currentMode.displayName) now. Trio returns to it after.")
                    : String(localized: "Switch to your usual dosing mode first, so Trio can return you to it"),
                state: modeAvailable ? .passed : .failed,
                info: SettingsTestInfo(
                    title: String(localized: "Starting from your usual mode"),
                    body: String(
                        localized: "Trio switches itself to Basal Testing for the fast and puts your usual dosing mode back afterwards, so it has to start from another mode."
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

        // Each is one line, a label and a value; anything longer is in its info sheet.

        private var glucoseCheck: Check {
            let value: String
            if let glucose = currentGlucose, let latest = recentReadings.first?.date {
                value = readingIsStale
                    ? String(
                        localized: "\(formatWithUnits(glucose)), \(SettingsTestFormat.duration(Date().timeIntervalSince(latest))) ago"
                    )
                    : formatWithUnits(glucose)
            } else {
                value = String(localized: "Waiting")
            }
            return Check(
                id: "glucose",
                title: String(localized: "Glucose now"),
                value: value,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Glucose now"),
                    body: String(
                        localized: "Your latest CGM reading, where the fast starts from; it's here for you to judge and doesn't hold up the start."
                    )
                )
            )
        }

        private var trendCheck: Check {
            let change = thirtyMinuteChange.map { SettingsTestFormat.keepTogether(formatChange($0), unit: glucoseUnits.rawValue) }
            let value: String
            let reading: String
            switch (trendArrow, change) {
            case let (arrow?, change?):
                value = String(localized: "\(arrow) \(change) in 30 min")
                reading = String(localized: "\(arrow) \(change) over the last 30 minutes")
            case let (arrow?, nil):
                value = arrow
                reading = String(localized: "\(arrow) Not enough readings yet for the last 30 minutes")
            case let (nil, change?):
                value = String(localized: "\(change) in 30 min")
                reading = String(localized: "\(change) over the last 30 minutes. Your CGM gave no arrow")
            case (nil, nil):
                value = String(localized: "Waiting")
                reading = String(localized: "Waiting for readings")
            }
            return Check(
                id: "trend",
                title: String(localized: "Trend"),
                value: value,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Trend"),
                    body: String(
                        localized: "The arrow is your CGM's own and the change is over the last 30 minutes; they're here for you to judge and don't hold up the start."
                    ),
                    reading: reading
                )
            )
        }

        private var iobCheck: Check {
            let units = String(localized: "\(currentIOB.formatted(.number.precision(.fractionLength(2)))) U")
            let amount = String(localized: "\(currentIOB.formatted(.number.precision(.fractionLength(2)))) U on board")
            let reading: String?
            switch BasalTestIOB(currentIOB) {
            case .positive: reading = String(localized: "\(amount): an earlier dose or SMB is still working")
            case .negative: reading = String(localized: "\(amount): Trio gave less than your scheduled basal lately")
            case .none: reading = nil
            }
            return Check(
                id: "iob",
                title: String(localized: "Insulin on board"),
                value: units,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Insulin on board"),
                    body: String(
                        localized: "Your scheduled basal is the zero point for insulin on board. Above zero, a dose or SMB is still working. Below zero, Trio gave less than your scheduled basal. It's here for you to judge and doesn't hold up the start."
                    ),
                    reading: reading,
                    quote: Docs.iobAroundZero,
                    links: [Docs.iobPatternsLink]
                )
            )
        }

        private var cobCheck: Check {
            Check(
                id: "cob",
                title: String(localized: "Carbs on board"),
                value: String(localized: "\(currentCOB.formatted(.number.precision(.fractionLength(0)))) g"),
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "Carbs on board"),
                    body: String(
                        localized: "The carbs Trio still counts as absorbing. The docs read insulin on board when you aren't eating and have no carbs on board, so more than zero here is worth a look. It doesn't hold up the start."
                    ),
                    quote: Docs.iobNotEating,
                    links: [Docs.iobPatternsLink]
                )
            )
        }

        /// The SMBs Trio gave while no carbs were on board, in the hours of the planned fast over the past week on
        /// the Check screen, or the finished test's hours over the week before it on the Result screen. Nil when
        /// the test ran under a minute, which has no hours to count.
        var smbCheck: Check? {
            guard let window = fastingWindow else { return nil }
            let found = fastingSMBCount(in: window)
            let value: String
            let reading: String?
            // Taken apart, because swiftformat turns `found.count > 0` on a tuple into `.isEmpty`.
            if let (smbCount, smbUnits) = found, smbCount > 0 {
                let count = smbCount == 1 ? String(localized: "1 SMB") : String(localized: "\(smbCount) SMBs")
                let units = smbUnits.formatted(.number.precision(.fractionLength(2)))
                value = String(localized: "\(count), \(units) U")
                reading = test == nil
                    ? String(localized: "\(count), \(units) U with no carbs on board, in these hours over the past week")
                    : String(
                        localized: "\(count), \(units) U with no carbs on board, in these hours over the week before the test"
                    )
            } else if found != nil {
                value = String(localized: "None")
                reading = test == nil
                    ? String(localized: "None in these hours over the past week")
                    : String(localized: "None in these hours over the week before the test")
            } else {
                value = String(localized: "Reading…")
                reading = nil
            }
            return Check(
                id: "smbs",
                title: String(localized: "SMBs while not eating"),
                value: value,
                state: .info,
                info: SettingsTestInfo(
                    title: String(localized: "SMBs while not eating"),
                    body: String(
                        localized: "SMBs are small boluses Trio gives on its own, and each one adds insulin on board. The docs read consistently positive IOB when you aren't eating as basal that may be too low for those hours. This only informs and doesn't change the result."
                    ),
                    reading: reading,
                    quote: Docs.iobPositive,
                    links: [Docs.iobPatternsLink]
                )
            )
        }

        /// The hours the SMB row counts: the planned fast on the Check screen, the test's own hours once it has one.
        private var fastingWindow: SettingsTestTimeWindow? {
            let start: Date
            let end: Date
            if let test {
                start = test.startedAt
                end = test.endedAt ?? test.plannedEnd
            } else {
                start = Date()
                end = start.addingTimeInterval(TimeInterval(selectedHours) * 3600)
            }
            let window = SettingsTestTimeWindow(from: start, to: end, calendar: .current)
            return window.startMinutes == window.endMinutes ? nil : window
        }

        /// Nil until the SMBs for this screen have been read.
        private func fastingSMBCount(in window: SettingsTestTimeWindow) -> (count: Int, units: Decimal)? {
            guard let source = fastingSource, source.testID == test?.id else { return nil }
            // On the Result screen it is the week before the test, so the fast itself isn't counted.
            let smbs = test.map { test in source.smbs.filter { $0.date < test.startedAt } } ?? source.smbs
            return BasalTestEvaluator.fastingSMBs(smbs, cob: source.cob, window: window)
        }

        // MARK: - Running

        var elapsed: TimeInterval {
            guard let test else { return 0 }
            return max(0, Date().timeIntervalSince(test.startedAt))
        }

        var remaining: TimeInterval {
            guard let test else { return 0 }
            return max(0, test.plannedEnd.timeIntervalSinceNow)
        }

        var progress: Double {
            guard let test, test.plannedDuration > 0 else { return 0 }
            return min(1, elapsed / test.plannedDuration)
        }

        /// Readings since the test began, oldest first.
        var runningReadings: [BasalTestReading] {
            guard let test else { return [] }
            return recentReadings.filter { $0.date >= test.startedAt }.sorted { $0.date < $1.date }
        }

        var readingIsStale: Bool {
            guard let latest = recentReadings.first?.date else { return true }
            return Date().timeIntervalSince(latest) > 15 * 60
        }

        /// How far glucose can move from where the fast started before it is worth one docs step of the scheduled
        /// basal, as a band around the start glucose in mg/dL. Nil without an ISF and a basal to work it out from.
        var steadyBand: ClosedRange<Int>? {
            guard let test, let isf = test.isf, let basal = test.scheduledBasal, isf > 0, basal > 0 else { return nil }
            let band = BasalTestEvaluator.steadyBand(
                isf: isf,
                scheduledBasal: basal,
                hours: Decimal(test.plannedDuration) / 3600
            )
            return (test.startGlucose - band) ... (test.startGlucose + band)
        }

        // MARK: - Result

        /// The finished test's result, worked out again from what it saved, with the rate and share behind it.
        var evaluation: BasalTestEvaluator.Evaluation? {
            test.flatMap { BasalTestEvaluator.evaluation(of: $0) }
        }

        /// The scheduled basal the result was judged against: the average over the hours the test ran.
        var resultBasal: Decimal? {
            guard let test, let end = test.endedAt else { return nil }
            return BasalTestEvaluator.scheduledBasal(for: test, endingAt: end)
        }

        /// Hours the finished test ran.
        var resultHours: Decimal? {
            guard let test, let end = test.endedAt else { return nil }
            return Decimal(end.timeIntervalSince(test.startedAt)) / 3600
        }

        /// The steady band over the hours the finished test ran and the basal it was judged against, so its edge is
        /// where the verdict changes. Nil without an ISF, a basal or any hours.
        var resultBand: ClosedRange<Int>? {
            guard let test, let isf = test.isf, let basal = resultBasal, let hours = resultHours,
                  isf > 0, basal > 0, hours > 0
            else { return nil }
            let band = BasalTestEvaluator.steadyBand(isf: isf, scheduledBasal: basal, hours: hours)
            return (test.startGlucose - band) ... (test.startGlucose + band)
        }

        // MARK: - Subscription

        override func subscribe() {
            if let runner = runner ?? testService.basalRunner {
                follow(runner)
            } else {
                warning(.settings, "BasalTest: the settings test service has no basal runner, so the screen can't run a test")
            }

            // A new reading changes nothing in the week of SMBs, so only a new determination reads it again.
            glucoseStorage.updatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { await self?.refresh(reloadingWeek: false) } }
                .store(in: &dataSubscriptions)

            CoreDataStack.shared.entityChangePublisher
                .receive(on: DispatchQueue.main)
                .filteredByEntityName("OrefDetermination")
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            // Right away, so the first frame doesn't show "No other test running" as passed.
            showSession(testService.activeSession, lastEnd: testService.lastEnd())
            testService.sessionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in self?.showSession(session, lastEnd: self?.testService.lastEnd()) }
                .store(in: &dataSubscriptions)

            Task { await refresh() }
        }

        /// Shows the service's session: the one running, and the one it last ended on its own (`lastEnd`), kept before it
        /// sent its end, so a fast whose session ended shows as ending (`isEnding`).
        func showSession(_ session: SettingsTestSession?, lastEnd: SettingsTestEnd?) {
            activeSessionKind = session?.kind
            serviceSession = (activeID: session?.id, lastEndID: lastEnd?.sessionID)
        }

        /// Whether the fast is ending, so its step takes neither End Now nor Discard (`SettingsTestModeRule.isEnding`): its
        /// ending is saved, or its session no longer runs while its runner's finish is to come.
        var isEnding: Bool {
            guard let test else { return false }
            return SettingsTestModeRule.isEnding(
                hasPendingEnd: test.pendingEnd != nil,
                isRunning: test.phase == .running,
                testSessionID: test.sessionID,
                session: serviceSession,
                mode: currentMode,
                previousMode: test.previousMode
            )
        }

        /// Shows the runner's fast now, so the first frame is its step, and each change it publishes, on the main queue.
        func follow(_ runner: BasalTestRunning) {
            self.runner = runner
            apply(runner.state)
            runner.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] test in self?.apply(test) }
                .store(in: &dataSubscriptions)
        }

        /// Shows the fast the runner publishes. The only place it changes. The fast on screen finishing has its Result's week
        /// of SMBs read, which a running fast doesn't read; a screen opened on a finished one reads it in `refresh`.
        func apply(_ test: BasalTestState?) {
            let finishes = test?.phase == .finished && self.test?.id == test?.id && self.test?.phase == .running
            self.test = test
            if finishes {
                Task { try? await loadFastingSource() }
            }
        }

        /// What `refresh` reads for the Check and Fast steps, shown in one step on the main actor (`show`).
        struct ScreenData {
            /// Newest first.
            var readings: [BasalTestReading]
            var iob: Decimal
            var cob: Decimal
            var lastCarb: Date?
            var hasActiveAdjustment: Bool
            var hasPumpSetTempBasal: Bool
            var hasDevices: Bool
            var trendDirection: BloodGlucose.Direction?
        }

        /// Shows what `refresh` read.
        func show(_ data: ScreenData) {
            recentReadings = data.readings
            currentIOB = data.iob
            currentCOB = data.cob
            lastCarb = data.lastCarb
            hasActiveAdjustment = data.hasActiveAdjustment
            hasPumpSetTempBasal = data.hasPumpSetTempBasal
            hasDevices = data.hasDevices
            trendDirection = data.trendDirection
        }

        /// Pulls fresh data, then has the runner check whether a running fast should stop. `reloadingWeek` false keeps the
        /// week of SMBs already read for the Check screen.
        func refresh(reloadingWeek: Bool = true) async {
            let reads = self.reads
            let schedule = reads.basalEntries()
            await MainActor.run { basalSchedule = schedule }
            do {
                let readings = try await reads.fetchRecentGlucose(minutes: 24 * 60)
                let iob = reads.getCurrentIOB()
                let cob = try await reads.getCurrentCOB()
                let carb = try await reads.lastCarbEntry(withinHours: 6)
                let adjustment = try await reads.hasActiveAdjustment()
                let pumpTempBasal = reads.hasPumpSetTempBasal()
                let devices = reads.hasCgmAndPump()
                let direction = try await reads.fetchNewestDirection()
                let data = ScreenData(
                    readings: readings,
                    iob: iob,
                    cob: cob,
                    lastCarb: carb,
                    hasActiveAdjustment: adjustment,
                    hasPumpSetTempBasal: pumpTempBasal,
                    hasDevices: devices,
                    trendDirection: direction
                )
                await MainActor.run { show(data) }
                try await loadFastingSource(reloadingWeek: reloadingWeek)
            } catch {
                await MainActor.run { errorMessage = "Couldn't read your data: \(error.localizedDescription)" }
            }
            await runner?.check()
        }

        /// Reads what the SMB row counts and keeps it. A running fast shows no such row, so it reads nothing then.
        private func loadFastingSource(reloadingWeek: Bool = true) async throws {
            let current = test
            guard current?.phase != .running else { return }
            // A finished test's week doesn't change, so it is read once; the Check screen's, when asked or not yet read.
            if fastingSource != nil, fastingSource?.testID == current?.id, current != nil || !reloadingWeek { return }
            // The week before the test, or before now on the Check screen.
            let since = (current?.startedAt ?? Date()).addingTimeInterval(-Config.smbLookback)
            let smbs = try await reads.fetchSMBs(since: since, until: .distantFuture)
            // From an hour earlier, so the first SMBs have a sample before them.
            let cob = try await reads.fetchCOBSamples(since: since.addingTimeInterval(-3600))
            let source = FastingSource(testID: current?.id, smbs: smbs, cob: cob)
            await MainActor.run { fastingSource = source }
        }

        // MARK: - Start

        /// What Start says without a recent glucose to start from: the ISF test's words for the same thing.
        private var noRecentGlucoseMessage: String {
            String(localized: "Trio has no recent glucose reading. Wait for your CGM's next reading, then try again.")
        }

        func requestStart() {
            guard readyToStart else { return }
            // The fast needs a recent glucose to start from (an app fact, as the devices are), and no row blocks on it.
            guard startGlucose != nil else {
                errorMessage = noRecentGlucoseMessage
                return
            }
            showStartConfirmation = true
        }

        /// Start: the runner saves the fast, starts its session and switches to Basal Testing. Only when every check
        /// passes, Basal Testing being off among them, so the runner never records it as the usual mode, and with a
        /// recent glucose to start from (`startGlucose`), none made up.
        @MainActor func confirmStart() {
            showStartConfirmation = false
            guard readyToStart else { return }
            // The reading may have grown too old while the confirmation was up.
            guard let glucose = startGlucose else {
                errorMessage = noRecentGlucoseMessage
                return
            }
            let begin = BasalTestBegin(glucose: glucose, iob: currentIOB, hours: selectedHours)
            // Start reads the carb entries there now before it switches the mode.
            Task { @MainActor in
                if let error = await runner?.begin(begin) {
                    errorMessage = error.message
                }
            }
        }

        // MARK: - Finish

        /// Has the runner check the fast now: the Fast step's timer.
        func checkRunningTest() async {
            await runner?.check()
        }

        /// End Now and See Result.
        func endEarly() async {
            guard await MainActor.run(body: { !isEnding }) else { return }
            await runner?.endEarly()
        }

        /// Whether Basal Testing is still on with no test running it, so the Result says so rather than that the usual
        /// dosing came back (`SettingsTestModeRule.basalTestingLeftOn`).
        var basalTestingLeftOn: Bool {
            SettingsTestModeRule.basalTestingLeftOn(mode: currentMode, activeSessionID: testService.activeSession?.id)
        }

        /// Stops without keeping a result.
        @MainActor func discard() {
            guard !isEnding else { return }
            runner?.discard()
            Task { await refresh() }
        }

        /// Clears a finished result so the user can start over.
        @MainActor func acknowledgeResult() {
            runner?.acknowledgeResult()
            Task { await refresh() }
        }
    }
}
