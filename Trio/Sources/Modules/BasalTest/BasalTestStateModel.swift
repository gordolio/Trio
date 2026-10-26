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
        private(set) var hasDevices = true

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

        func formatWithUnits(_ mgdl: Int) -> String {
            mgdl.formatted(withUnits: glucoseUnits)
        }

        /// A change in glucose with its sign, e.g. "+22".
        func formatChange(_ mgdl: Int) -> String {
            let value = glucoseUnits == .mmolL ? Double(truncating: abs(mgdl).asMmolL as NSNumber) : Double(abs(mgdl))
            let text = glucoseUnits == .mmolL ? String(format: "%.1f", value) : "\(Int(value))"
            return (mgdl < 0 ? "-" : "+") + text
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

        var glucoseInRange: Bool {
            currentGlucose.map { Config.startRange.contains($0) } ?? false
        }

        /// Glucose changed little over the last half hour or so.
        var glucoseFlat: Bool {
            guard recentReadings.count >= 6, let newest = recentReadings.first?.glucose,
                  let oldest = recentReadings.prefix(9).last?.glucose
            else { return false }
            return abs(newest - oldest) <= 15
        }

        var fastedLongEnough: Bool {
            guard let lastCarb else { return true }
            return Date().timeIntervalSince(lastCarb) >= Config.fastBeforeStart
        }

        var iobSettled: Bool { currentIOB <= Config.maxStartIOB }
        var cobClear: Bool { currentCOB <= 1 }
        var modeAvailable: Bool { currentMode != .basalTesting }

        struct Check: Identifiable {
            let id: String
            let title: String
            let detail: String
            let state: SettingsTestCheckState
        }

        var checks: [Check] {
            let range = Config.startRange
            let low = format(range.lowerBound)
            let high = format(range.upperBound)

            let glucoseDetail: String = currentGlucose
                .map { "\(formatWithUnits($0))" + (glucoseInRange ? "" : " — needs to be \(low)–\(high)") }
                ?? String(localized: "Waiting for a reading")

            let flatDetail: String
            if glucoseFlat {
                flatDetail = String(localized: "Steady over the last half hour")
            } else if recentReadings.count < 6 {
                flatDetail = String(localized: "Needs about 30 minutes of readings")
            } else {
                flatDetail = String(localized: "Still moving — wait for it to settle")
            }

            let fastDetail: String
            if let lastCarb {
                let ago = Date().timeIntervalSince(lastCarb)
                fastDetail = fastedLongEnough
                    ? String(localized: "Last carbs \(SettingsTestFormat.duration(ago)) ago")
                    : String(
                        localized: "Last carbs \(SettingsTestFormat.duration(ago)) ago — wait until 2 h have passed"
                    )
            } else {
                fastDetail = String(localized: "No carbs logged in the last 6 hours")
            }

            return [
                Check(
                    id: "devices",
                    title: String(localized: "CGM and pump connected"),
                    detail: hasDevices ? String(localized: "Both are connected") : String(
                        localized: "Connect a CGM and a pump first"
                    ),
                    state: hasDevices ? .passed : .failed
                ),
                Check(
                    id: "glucose",
                    title: String(localized: "Glucose in range"),
                    detail: glucoseDetail,
                    state: currentGlucose == nil ? .pending : (glucoseInRange ? .passed : .failed)
                ),
                Check(
                    id: "flat",
                    title: String(localized: "Glucose steady"),
                    detail: flatDetail,
                    state: glucoseFlat ? .passed : .pending
                ),
                Check(
                    id: "fast",
                    title: String(localized: "No food for 2 hours"),
                    detail: fastDetail,
                    state: fastedLongEnough ? .passed : .failed
                ),
                Check(
                    id: "iob",
                    title: String(localized: "No recent bolus"),
                    detail: String(
                        localized: "\(currentIOB.formatted(.number.precision(.fractionLength(2)))) U on board"
                    ),
                    state: iobSettled ? .passed : .failed
                ),
                Check(
                    id: "cob",
                    title: String(localized: "No carbs still absorbing"),
                    detail: String(localized: "\(currentCOB.formatted(.number.precision(.fractionLength(0)))) g on board"),
                    state: cobClear ? .passed : .failed
                ),
                Check(
                    id: "adjustments",
                    title: String(localized: "No override or temp target"),
                    detail: hasActiveAdjustment
                        ? String(localized: "End it first — it changes your basal and sensitivity")
                        : String(localized: "None running"),
                    state: hasActiveAdjustment ? .failed : .passed
                ),
                Check(
                    id: "mode",
                    title: String(localized: "Basal Testing is off"),
                    detail: modeAvailable
                        ? String(localized: "Currently \(currentMode.displayName)")
                        : String(localized: "Switch to your usual dosing mode first, so Trio can return you to it"),
                    state: modeAvailable ? .passed : .failed
                )
            ]
        }

        var readyToStart: Bool {
            checks.allSatisfy { $0.state == .passed }
        }

        var passingCount: Int { checks.filter { $0.state == .passed }.count }

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

        var isHigh: Bool { (currentGlucose ?? 0) >= Config.highSuggestEnd }

        // MARK: - Subscription

        override func subscribe() {
            test = provider.storage.retrieve(Config.statePath, as: BasalTestState.self)

            glucoseStorage.updatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            CoreDataStack.shared.entityChangePublisher
                .receive(on: DispatchQueue.main)
                .filteredByEntityName("OrefDetermination")
                .sink { [weak self] _ in Task { await self?.refresh() } }
                .store(in: &dataSubscriptions)

            Task { await refresh() }
        }

        /// Pulls fresh data, then checks whether a running fast should stop.
        func refresh() async {
            do {
                let readings = try await provider.fetchRecentGlucose(minutes: 24 * 60)
                let iob = provider.getCurrentIOB()
                let cob = try await provider.getCurrentCOB()
                let carb = try await provider.lastCarbEntry(withinHours: 6)
                let adjustment = try await provider.hasActiveAdjustment()
                let devices = provider.hasCgmAndPump()
                await MainActor.run {
                    recentReadings = readings
                    currentIOB = iob
                    currentCOB = cob
                    lastCarb = carb
                    hasActiveAdjustment = adjustment
                    hasDevices = devices
                }
            } catch {
                await MainActor.run { errorMessage = "Couldn't read your data: \(error.localizedDescription)" }
            }
            await checkRunningTest()
        }

        // MARK: - Start

        func requestStart() {
            guard readyToStart else { return }
            showStartConfirmation = true
        }

        func confirmStart() {
            showStartConfirmation = false
            guard readyToStart, let glucose = currentGlucose else { return }

            let now = Date()
            let duration = TimeInterval(selectedHours) * 3600
            let previous = currentMode
            let state = BasalTestState(
                startedAt: now,
                plannedDuration: duration,
                startGlucose: glucose,
                startIOB: currentIOB,
                previousMode: previous,
                timeBlock: BasalTestEvaluator.timeBlock(for: now)
            )

            // Register the way back before changing anything, so an interruption can't leave the user
            // in Basal Testing with nobody watching it.
            testService.begin(
                kind: .basal,
                expiresIn: duration + Config.expiryGrace,
                restoring: [.dosingMode(testMode: .basalTesting, previous: previous)]
            )
            settingsManager.settings.dosingMode = .basalTesting
            provider.storage.save(state, as: Config.statePath)
            test = state
            scheduleFinishedNotification(at: state.plannedEnd)
        }

        // MARK: - Finish

        /// Ends the fast if its time is up, glucose went low, or something spoiled it.
        func checkRunningTest() async {
            guard let test, test.phase == .running else { return }

            if let glucose = currentGlucose, !readingIsStale, glucose < Config.lowStop {
                await finish(reason: .low)
            } else if Date() >= test.plannedEnd {
                await finish(reason: .completed)
            } else if await wasInterrupted(test, until: Date()) != nil {
                await finish(reason: .interrupted)
            }
        }

        func endEarly() async {
            await finish(reason: .endedEarly)
        }

        /// Stops without keeping a result.
        func discard() {
            testService.end()
            clearTest()
            cancelFinishedNotification()
        }

        func finish(reason: BasalTestEndReason) async {
            guard var current = test, current.phase == .running, !isFinishing else { return }
            isFinishing = true
            defer { isFinishing = false }

            // Normal dosing comes back first; the rest is bookkeeping.
            testService.end()
            cancelFinishedNotification()

            // A test that ran out while the app was closed covers only its planned window.
            let end = min(Date(), current.plannedEnd)
            let readings = (try? await provider.fetchGlucose(from: current.startedAt, to: end)) ?? []
            let endGlucose = BasalTestEvaluator.endGlucose(from: readings, fallback: current.startGlucose)
            let interference = await wasInterrupted(current, until: end)

            let evaluation = BasalTestEvaluator.evaluate(
                startGlucose: current.startGlucose,
                endGlucose: endGlucose,
                elapsed: end.timeIntervalSince(current.startedAt),
                planned: current.plannedDuration,
                reason: reason,
                interference: interference
            )

            current.phase = .finished
            current.endedAt = end
            current.endReason = reason
            current.endGlucose = endGlucose
            current.readings = readings
            current.outcome = evaluation.outcome
            current.interference = interference
            provider.storage.save(current, as: Config.statePath)

            if evaluation.outcome.isConclusive, let direction = evaluation.direction {
                testService.archive(
                    SettingsTestRecord(
                        kind: .basal,
                        startedAt: current.startedAt,
                        completedAt: end,
                        timeBlock: current.timeBlock,
                        startGlucose: current.startGlucose,
                        endGlucose: endGlucose,
                        direction: direction,
                        summary: summary(for: evaluation.outcome)
                    )
                )
            }

            let finished = current
            await MainActor.run { test = finished }
        }

        /// What spoiled the fast, if anything.
        private func wasInterrupted(_ test: BasalTestState, until end: Date) async -> String? {
            if (try? await provider.hasCarbEntries(from: test.startedAt, to: end)) == true {
                return String(localized: "Carbs were logged during the fast.")
            }
            if (try? await provider.hasManualBolus(from: test.startedAt, to: end)) == true {
                return String(localized: "A bolus was given during the fast.")
            }
            return nil
        }

        /// Clears a finished result so the user can start over.
        func acknowledgeResult() {
            clearTest()
        }

        private func clearTest() {
            provider.storage.remove(Config.statePath)
            test = nil
        }

        func summary(for outcome: BasalTestOutcome) -> String {
            switch outcome {
            case .steady: return String(localized: "Glucose stayed steady")
            case .rising: return String(localized: "Glucose rose")
            case .falling: return String(localized: "Glucose fell")
            case .inconclusive: return String(localized: "Ended too soon to tell")
            case .invalid: return String(localized: "Fast was interrupted")
            }
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
