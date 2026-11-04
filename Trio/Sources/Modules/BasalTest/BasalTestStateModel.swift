import Combine
import CoreData
import Foundation
import Observation
import SwiftUI
import UserNotifications

extension BasalTest {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!

        // MARK: - State

        /// The test in progress or just finished. `nil` while the user is still getting ready.
        var test: BasalTestState?

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
        @ObservationIgnored private var isFinishing = false

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
            test = provider.storage.retrieve(Config.statePath, as: BasalTestState.self)

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
            activeSessionKind = testService.activeSession?.kind
            testService.sessionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in self?.activeSessionKind = session?.kind }
                .store(in: &dataSubscriptions)

            Task { await refresh() }
        }

        /// Pulls fresh data, then checks whether a running fast should stop. `reloadingWeek` false keeps the week of SMBs
        /// already read for the Check screen.
        func refresh(reloadingWeek: Bool = true) async {
            let schedule = provider.basalEntries()
            await MainActor.run { basalSchedule = schedule }
            do {
                let readings = try await provider.fetchRecentGlucose(minutes: 24 * 60)
                let iob = provider.getCurrentIOB()
                let cob = try await provider.getCurrentCOB()
                let carb = try await provider.lastCarbEntry(withinHours: 6)
                let adjustment = try await provider.hasActiveAdjustment()
                let pumpTempBasal = provider.hasPumpSetTempBasal()
                let devices = provider.hasCgmAndPump()
                let direction = try await provider.fetchNewestDirection()
                await MainActor.run {
                    recentReadings = readings
                    currentIOB = iob
                    currentCOB = cob
                    lastCarb = carb
                    hasActiveAdjustment = adjustment
                    hasPumpSetTempBasal = pumpTempBasal
                    hasDevices = devices
                    trendDirection = direction
                }
                try await loadFastingSource(reloadingWeek: reloadingWeek)
            } catch {
                await MainActor.run { errorMessage = "Couldn't read your data: \(error.localizedDescription)" }
            }
            await checkRunningTest()
        }

        /// Reads what the SMB row counts and keeps it. A running fast shows no such row, so it reads nothing then.
        private func loadFastingSource(reloadingWeek: Bool = true) async throws {
            let current = test
            guard current?.phase != .running else { return }
            // A finished test's week doesn't change, so it is read once; the Check screen's, when asked or not yet read.
            if fastingSource != nil, fastingSource?.testID == current?.id, current != nil || !reloadingWeek { return }
            // The week before the test, or before now on the Check screen.
            let since = (current?.startedAt ?? Date()).addingTimeInterval(-Config.smbLookback)
            let smbs = try await provider.fetchSMBs(since: since)
            // From an hour earlier, so the first SMBs have a sample before them.
            let cob = try await provider.fetchCOBSamples(since: since.addingTimeInterval(-3600))
            let source = FastingSource(testID: current?.id, smbs: smbs, cob: cob)
            await MainActor.run { fastingSource = source }
        }

        // MARK: - Start

        func requestStart() {
            guard readyToStart else { return }
            // The fast needs a glucose to start from, and no row blocks on it.
            guard currentGlucose != nil else {
                errorMessage =
                    String(localized: "Trio has no glucose reading yet. Wait for your CGM's next reading, then try again.")
                return
            }
            showStartConfirmation = true
        }

        func confirmStart() {
            showStartConfirmation = false
            guard readyToStart, let glucose = currentGlucose else { return }

            let now = Date()
            let duration = TimeInterval(selectedHours) * 3600
            let previous = currentMode
            // What the test runs on, kept so the result and a later check of the schedule don't depend on
            // what the settings say by then.
            let snapshot = BasalTestEvaluator.snapshot(of: provider.basalEntries(), startingAt: now, for: duration)
            var state = BasalTestState(
                startedAt: now,
                plannedDuration: duration,
                startGlucose: glucose,
                startIOB: currentIOB,
                previousMode: previous,
                timeBlock: BasalTestEvaluator.timeBlock(for: now),
                isf: provider.isf(at: now),
                scheduledBasal: snapshot.scheduledBasal,
                coveredEntries: snapshot.covered
            )

            // Saved first, so a crash from here on leaves a fast this screen can finish: one that never reached Basal
            // Testing ends as interrupted.
            provider.storage.save(state, as: Config.statePath)
            // Register the way back before changing anything, so an interruption can't leave the user
            // in Basal Testing with nobody watching it.
            guard let session = testService.begin(
                kind: .basal,
                expiresIn: duration + Config.expiryGrace,
                restoring: [.dosingMode(testMode: .basalTesting, previous: previous)]
            ) else {
                provider.storage.remove(Config.statePath)
                errorMessage = String(localized: "Another settings test is running. Finish it first.")
                return
            }
            // Saved again with its session, before the mode changes, so the service's record of ending it for a low
            // or for carbs can be matched to this test.
            state.sessionID = session.id
            provider.storage.save(state, as: Config.statePath)
            settingsManager.settings.dosingMode = .basalTesting
            test = state
            scheduleFinishedNotification(at: state.plannedEnd)
        }

        // MARK: - Finish

        /// Ends the fast if the service ended it for a low or for carbs, Trio suspended insulin for a low, its time is up,
        /// the dosing mode was changed, or something spoiled it.
        func checkRunningTest() async {
            guard let test, test.phase == .running, !isFinishing else { return }
            // What the check finishes below is this fast, and only this one: the reads in between give the user time to
            // discard it and start another, which this check knows nothing about.
            let testID = test.id

            let now = Date()
            // Only the fast itself: a zero temp after the planned end isn't this test's low.
            let end = min(now, test.plannedEnd)
            let suspend: BasalTestEvaluator.SuspendReading
            do {
                suspend = try await provider.fetchSuspendReading(from: test.startedAt, to: end)
            } catch {
                // Without them a low can't be told from a fast that ran its course. Before the planned end nothing is
                // decided on them this time; at it, the fast still ends, without a verdict.
                warning(.settings, "BasalTest: couldn't read temp basals to check for a low", error: error)
                suspend = .unreadable
            }

            // Read together on the main actor, where the service keeps its record before it brings the usual mode
            // back, so a mode changed by the service is never seen without the reason.
            let (mode, serviceEnd) = await MainActor.run { (currentMode, testService.lastEnd()) }
            switch BasalTestEvaluator.runningCheck(
                sessionID: test.sessionID,
                serviceEnd: serviceEnd,
                suspend: suspend,
                now: now,
                plannedEnd: test.plannedEnd,
                mode: mode
            ) {
            case let .low(suspendedAt):
                await finish(for: testID, reason: .low, at: suspendedAt)
            case let .carbsLogged(endedAt):
                await finish(
                    for: testID,
                    reason: .interrupted,
                    at: endedAt,
                    note: String(localized: "Carbs were logged during the fast.")
                )
            case let .bolusGiven(endedAt):
                await finish(
                    for: testID,
                    reason: .interrupted,
                    at: endedAt,
                    note: String(localized: "A bolus was given during the fast.")
                )
            case .completed:
                await finish(for: testID, reason: .completed)
            case .completedUnchecked:
                await finish(for: testID, reason: .unchecked)
            case .modeChanged:
                await finish(
                    for: testID,
                    reason: .interrupted,
                    note: String(localized: "The dosing mode changed during the fast.")
                )
            case .modeChangedRestored:
                await finish(
                    for: testID,
                    reason: .interrupted,
                    note: String(
                        localized: "The dosing mode changed during the fast, so it has no result. Your usual dosing mode is back."
                    )
                )
            case let .unexplainedSuspend(stoppedAt):
                await finish(
                    for: testID,
                    reason: .interrupted,
                    at: stoppedAt,
                    note: BasalTestEvaluator.basalStoppedNote
                )
            case let .carbsUnreadable(endedAt):
                await finish(
                    for: testID,
                    reason: .interrupted,
                    at: endedAt,
                    note: String(
                        localized: "Trio couldn't read your carbs to check the fast, so it brought your usual dosing back."
                    )
                )
            case nil:
                if case .found = await wasInterrupted(test, until: now) {
                    await finish(for: testID, reason: .interrupted)
                }
            }
        }

        func endEarly() async {
            await finish(reason: .endedEarly)
        }

        /// Whether Basal Testing is still on with no test running it, so the Result says so rather than that the usual
        /// dosing came back (`SettingsTestModeRule.basalTestingLeftOn`).
        var basalTestingLeftOn: Bool {
            SettingsTestModeRule.basalTestingLeftOn(mode: currentMode, activeSessionID: testService.activeSession?.id)
        }

        /// Stops without keeping a result.
        func discard() {
            testService.end(kind: .basal)
            clearTest()
            cancelFinishedNotification()
        }

        /// `endedAt` is when a low ended the fast, when basal was stopped in a way Trio can't put down to a low, or when the
        /// service ended it for carbs; without it the fast ends now, or at the planned end if that came first. `note`
        /// says what interrupted it when the records don't. `reason` is what the caller saw; the history up to the end
        /// can still make it a low or an interruption (`settle`). With `testID`, it finishes only that fast: a check that
        /// read the history for one fast must not end another that was started while it waited.
        func finish(
            for testID: UUID? = nil,
            reason: BasalTestEndReason,
            at endedAt: Date? = nil,
            note: String? = nil
        ) async {
            // Claimed on the main actor, where Discard and Start run, so the claim and the save below are ordered with
            // them.
            let claimed: BasalTestState? = await MainActor.run {
                guard let current = test, current.phase == .running, !isFinishing,
                      testID == nil || current.id == testID
                else { return nil }
                isFinishing = true
                return current
            }
            guard var current = claimed else { return }

            // Fixed before normal dosing comes back, so nothing the usual mode does next falls inside the fast. A test
            // that ran out while the app was closed covers only its planned window, and a low only up to the suspend.
            let endedBy = min(endedAt ?? Date(), current.plannedEnd)

            // Normal dosing comes back first; the rest is bookkeeping.
            testService.end(kind: .basal)
            cancelFinishedNotification()

            // The history up to the end decides how the fast ended, so a low the periodic checks hadn't seen yet isn't
            // lost. Read once normal dosing is back, so the read never holds it up.
            let (reason, end, stopped) = await settle(current, reason: reason, at: endedBy)
            let note = note ?? stopped

            let readings: [BasalTestReading]
            do {
                readings = try await provider.fetchGlucose(from: current.startedAt, to: end)
            } catch {
                warning(.settings, "BasalTest: couldn't read the fast's glucose", error: error)
                readings = []
            }
            let endGlucose = BasalTestEvaluator.endGlucose(from: readings, endingAt: end)
            let checked = await wasInterrupted(current, until: end)
            let interference: String?
            if case let .found(message) = checked {
                interference = message
            } else {
                interference = note
            }
            let interferenceUnread = checked == .unreadable

            let evaluation = BasalTestEvaluator.evaluate(
                startGlucose: current.startGlucose,
                endGlucose: endGlucose,
                elapsed: end.timeIntervalSince(current.startedAt),
                reason: reason,
                interference: interference,
                interferenceUnread: interferenceUnread,
                isf: current.isf,
                scheduledBasal: BasalTestEvaluator.scheduledBasal(for: current, endingAt: end)
            )

            current.phase = .finished
            current.endedAt = end
            current.endReason = reason
            current.endGlucose = endGlucose
            current.readings = readings
            current.outcome = evaluation.outcome
            current.interference = interference
            current.interferenceUnread = interferenceUnread

            var record: SettingsTestRecord?
            if evaluation.outcome.isConclusive, let direction = evaluation.direction {
                record = SettingsTestRecord(
                    kind: .basal,
                    startedAt: current.startedAt,
                    completedAt: end,
                    timeBlock: current.timeBlock,
                    startGlucose: current.startGlucose,
                    // Only a low can get here without one: it says falling whatever the readings were.
                    endGlucose: endGlucose ?? current.startGlucose,
                    direction: direction,
                    summary: BasalTestEvaluator.summary(for: evaluation.outcome, reason: reason),
                    // Only what the hours it ran covered, so a fast ended early doesn't vouch for the rest.
                    coveredEntries: BasalTestEvaluator.coveredEntries(for: current, endingAt: end)
                )
            }

            // Kept only if it is still the fast on screen: a Discard or a new Start while the history was read owns the
            // screen and the saved state now. One step on the main actor, so neither can come in between.
            let finished = current
            let archived = record
            let kept = await MainActor.run { () -> Bool in
                isFinishing = false
                guard let shown = test, shown.id == finished.id, shown.phase == .running else { return false }
                provider.storage.save(finished, as: Config.statePath)
                if let archived {
                    testService.archive(archived)
                }
                test = finished
                return true
            }
            guard kept else { return }
            try? await loadFastingSource()
        }

        /// How the fast ends, from what the pump history and Trio's determinations up to `end` say: see
        /// `BasalTestEvaluator.finishing`. A low or an interruption already decided needs no read.
        private func settle(
            _ test: BasalTestState,
            reason: BasalTestEndReason,
            at end: Date
        ) async -> (reason: BasalTestEndReason, end: Date, note: String?) {
            guard reason != .low, reason != .interrupted else { return (reason, end, nil) }
            let suspend: BasalTestEvaluator.SuspendReading
            do {
                suspend = try await provider.fetchSuspendReading(from: test.startedAt, to: end)
            } catch {
                warning(.settings, "BasalTest: couldn't read temp basals to check the finished fast for a low", error: error)
                suspend = .unreadable
            }
            return BasalTestEvaluator.finishing(reason: reason, at: end, suspend: suspend)
        }

        /// What spoiled the fast, if anything: carbs, a bolus, or Trio dosing, which it doesn't in Basal Testing. Each
        /// record is read on its own, so one that can't be read is logged without hiding what the others show; with
        /// nothing found, the fast is left unchecked.
        private func wasInterrupted(_ test: BasalTestState, until end: Date) async -> BasalTestEvaluator.Interference {
            let start = test.startedAt
            let provider: Provider = self.provider
            return await BasalTestEvaluator.firstInterference(BasalTestEvaluator.interferenceChecks(
                hasCarbs: { try await provider.hasCarbEntries(from: start, to: end) },
                hasManualBolus: { try await provider.hasManualBolus(from: start, to: end) },
                smbs: { try await provider.fetchSMBs(since: start, until: end) },
                temps: { try await provider.fetchTempBasals(from: start, to: end) },
                since: start,
                until: end
            ))
        }

        /// Clears a finished result so the user can start over.
        func acknowledgeResult() {
            clearTest()
        }

        private func clearTest() {
            provider.storage.remove(Config.statePath)
            test = nil
            Task { await refresh() }
        }

        // MARK: - Notifications

        private func scheduleFinishedNotification(at date: Date) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Basal test finished")
            content.body = String(localized: "Open Trio to see how your basal held up.")
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "Trio.basalTestFinished",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            )
            UNUserNotificationCenter.current().add(request)
        }

        private func cancelFinishedNotification() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["Trio.basalTestFinished"])
            center.removeDeliveredNotifications(withIdentifiers: ["Trio.basalTestFinished"])
        }
    }
}
