import Combine
import CoreData
import Foundation
import SwiftUI
import Swinject

/// Simple struct to hold glucose reading data extracted from Core Data
/// This is Sendable-safe since it only contains value types
private struct PreflightGlucoseReading: Sendable {
    let glucose: Int
    let direction: BloodGlucose.Direction?
}

extension CarbRatioCalibration {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var calibrationService: CalibrationModeService!
        @ObservationIgnored @Injected() var iobService: IOBService!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!

        // MARK: - Published State

        /// Current wizard step
        var currentStep: Step = .preflight

        /// Current test state from service
        var testState: CalibrationTestState?

        /// Recent glucose values for preflight (extracted from Core Data)
        private var recentGlucoseValues: [PreflightGlucoseReading] = []

        /// Current glucose value
        var currentGlucose: Int?

        /// Current glucose direction
        var currentDirection: BloodGlucose.Direction?

        /// Current IOB
        var currentIOB: Decimal = 0

        /// Predicted IOB values at 5-minute intervals from the latest OpenAPS run
        private var iobPredictions: [IOBEntry] = []

        /// Current COB
        var currentCOB: Decimal = 0

        /// Current carb ratio
        var currentCarbRatio: Decimal = 10

        /// Selected tablet brand
        var selectedBrand: GlucoseTabletBrand = .dex4

        /// Number of tablets to consume
        var tabletCount: Int = 2

        /// Error message if any
        var errorMessage: String?

        /// Show confirmation alert before starting test
        var showStartTestConfirmation: Bool = false

        /// Show confirmation dialog before prep (SMB will be disabled)
        var showPrepConfirmation: Bool = false

        /// Show ratio update options
        var showRatioUpdateOptions: Bool = false

        /// Prep monitoring timer
        @ObservationIgnored private var prepMonitorTimer: Timer?

        /// Prep start time for timeout calculation
        @ObservationIgnored private var prepStartTime: Date?

        /// Timestamp when the user first opened the calibration screen (for BG capture range)
        @ObservationIgnored private var preflightOpenedDate: Date?

        /// Core Data observer for auto-refreshing preflight data
        @ObservationIgnored private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
        @ObservationIgnored private var dataSubscriptions = Set<AnyCancellable>()

        // MARK: - Unit Preferences

        /// User's preferred glucose units
        /// Returns mg/dL as default if settingsManager hasn't been injected yet (e.g., during Preview)
        var glucoseUnits: GlucoseUnits {
            // Safely check implicitly unwrapped optional before injection
            // settingsManager is declared as SettingsManager! (IUO), so we need to cast to optional first
            let manager: SettingsManager? = settingsManager
            return manager?.settings.units ?? .mgdL
        }

        /// Target range lower bound in mg/dL (internal)
        private let targetRangeLowMgdL = 90
        /// Target range upper bound in mg/dL (internal)
        private let targetRangeHighMgdL = 120
        /// Tolerance for result interpretation in mg/dL (internal)
        private let toleranceMgdL = 20

        /// Target range description in user's preferred units
        var targetRangeDescription: String {
            if glucoseUnits == .mmolL {
                let low = targetRangeLowMgdL.asMmolL
                let high = targetRangeHighMgdL.asMmolL
                return "\(low)-\(high) mmol/L"
            }
            return "\(targetRangeLowMgdL)-\(targetRangeHighMgdL) mg/dL"
        }

        /// Format glucose value in user's preferred units
        func formatGlucose(_ value: Int) -> String {
            if glucoseUnits == .mmolL {
                return value.formattedAsMmolL
            }
            return "\(value)"
        }

        /// Units suffix for display
        var unitsLabel: String {
            glucoseUnits.rawValue
        }

        // MARK: - Computed Properties

        var isGlucoseInRange: Bool {
            guard let bg = currentGlucose else { return false }
            return bg >= targetRangeLowMgdL && bg <= targetRangeHighMgdL
        }

        var isGlucoseFlat: Bool {
            guard recentGlucoseValues.count >= 6 else { return false }

            // Check if delta over the last ~45 minutes is within tolerance
            let readings = Array(recentGlucoseValues.prefix(9))
            guard let newest = readings.first?.glucose,
                  let oldest = readings.last?.glucose
            else {
                return false
            }

            let delta = abs(newest - oldest)
            return delta <= 15 // Within 15 mg/dL over the period
        }

        /// Subtitle text for the glucose trend flat check item.
        /// Shows estimated wait time when not stable, or confirmation when stable.
        var glucoseFlatSubtitle: String {
            if isGlucoseFlat {
                return "Stable over last \(recentGlucoseValues.count * 5) minutes"
            }

            let readingCount = recentGlucoseValues.count
            if readingCount < 6 {
                // Need at least 6 readings (30 min) to even evaluate
                let minutesNeeded = (6 - readingCount) * 5
                return "Need \(minutesNeeded) more min of data (have \(readingCount * 5) of 30 min)"
            }

            // Have enough readings but glucose isn't flat — check the delta
            let readings = Array(recentGlucoseValues.prefix(9))
            if let newest = readings.first?.glucose,
               let oldest = readings.last?.glucose
            {
                let delta = abs(newest - oldest)
                return "Glucose moved \(delta) mg/dL (limit: 15) — wait for it to settle"
            }

            return "Trend not yet stable"
        }

        var isIOBNearZero: Bool {
            currentIOB <= 0.1
        }

        /// Estimated minutes until IOB decays to ≤ 0.1 U, or nil if already passing or data unavailable.
        ///
        /// Reads the IOB prediction array from the latest OpenAPS run (48 entries at 5-min intervals,
        /// covering 4 hours). Finds the first entry where predicted IOB ≤ 0.1 U.
        var estimatedMinutesUntilIOBReady: Int? {
            guard !isIOBNearZero else { return nil }
            guard iobPredictions.count > 1 else { return nil }

            // Each entry in the array is 5 minutes apart (indices 0..47 → 0..235 min)
            // Find the first prediction where IOB drops to ≤ 0.1
            for (index, entry) in iobPredictions.enumerated() {
                if entry.iob <= 0.1 {
                    return max(5, index * 5)
                }
            }

            // IOB doesn't drop below 0.1 within the prediction window (4 hours)
            // Return the end of the window as a lower bound
            return iobPredictions.count * 5
        }

        /// Subtitle text for the IOB check item, including estimated wait time when failing
        var iobSubtitle: String {
            let iobText = "\(currentIOB.formatted(.number.precision(.fractionLength(2))))U on board"
            if isIOBNearZero {
                return iobText
            }
            if let minutes = estimatedMinutesUntilIOBReady {
                let hours = minutes / 60
                let remainingMin = minutes % 60
                let timeString = hours > 0 ? "~\(hours)h \(remainingMin)m" : "~\(remainingMin) min"
                return "\(iobText) — est. \(timeString) to clear"
            }
            return iobText
        }

        var isCOBNearZero: Bool {
            currentCOB <= 5
        }

        var preflightPassed: Bool {
            isGlucoseInRange && isGlucoseFlat && isIOBNearZero && isCOBNearZero
        }

        var totalCarbs: Decimal {
            selectedBrand.totalCarbs(for: tabletCount)
        }

        var calculatedBolus: Decimal {
            guard currentCarbRatio > 0 else { return 0 }
            return selectedBrand.bolusAmount(for: tabletCount, carbRatio: currentCarbRatio)
        }

        /// Number of preflight conditions currently passing
        var conditionsPassingCount: Int {
            [isGlucoseInRange, isGlucoseFlat, isIOBNearZero, isCOBNearZero].filter(\.self).count
        }

        /// Total number of preflight conditions
        var conditionsTotalCount: Int { 4 }

        /// Time elapsed since prep started
        var prepElapsedTime: TimeInterval {
            guard let start = prepStartTime else { return 0 }
            return Date().timeIntervalSince(start)
        }

        /// Prep timeout duration in seconds
        var prepTimeoutDuration: TimeInterval {
            Double(calibrationService.prepTimeoutMinutes) * 60
        }

        /// Time remaining before prep times out
        var prepTimeRemaining: TimeInterval {
            max(0, prepTimeoutDuration - prepElapsedTime)
        }

        /// Summary of what conditions still need to pass
        var pendingConditionsSummary: String {
            var pending: [String] = []
            if !isGlucoseInRange { pending.append("BG in range (\(targetRangeLowMgdL)–\(targetRangeHighMgdL))") }
            if !isGlucoseFlat { pending.append("stable trend") }
            if !isIOBNearZero { pending.append("IOB ≤ 0.1 U") }
            if !isCOBNearZero { pending.append("COB ≤ 5 g") }
            if pending.isEmpty { return "All conditions met" }
            return "Waiting for: " + pending.joined(separator: ", ")
        }

        var observationTimeRemaining: TimeInterval {
            guard let endDate = testState?.observationEndDate else { return 0 }
            return max(0, endDate.timeIntervalSinceNow)
        }

        var observationProgress: Double {
            guard let endDate = testState?.observationEndDate else { return 0 }
            let totalDuration: TimeInterval = 90 * 60 // 90 minutes
            let remaining = max(0, endDate.timeIntervalSinceNow)
            return min(1.0, max(0, 1.0 - remaining / totalDuration))
        }

        // MARK: - Subscription

        override func subscribe() {
            // Subscribe to test state changes
            calibrationService.testStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.testState = state
                    self?.updateStepFromPhase()
                }
                .store(in: &lifetime)

            // Auto-refresh when new glucose data arrives (batch inserts use this publisher)
            glucoseStorage.updatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { [weak self] in
                        await self?.refreshPreflightData()
                    }
                }
                .store(in: &dataSubscriptions)

            // Auto-refresh when new determinations arrive (updates IOB/COB)
            coreDataPublisher =
                CoreDataStack.shared.entityChangePublisher
                    .receive(on: DispatchQueue.main)
                    .share()
                    .eraseToAnyPublisher()

            coreDataPublisher?.filteredByEntityName("OrefDetermination")
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { [weak self] in
                        await self?.refreshPreflightData()
                    }
                }
                .store(in: &dataSubscriptions)

            // Record when the user opened the screen (for BG capture range)
            preflightOpenedDate = Date()

            // Recover any persisted test state (handles app restarts) and fetch initial data
            Task {
                await calibrationService.recoverTestStateIfNeeded()
                testState = calibrationService.currentTest

                // If recovering, use the persisted preflightStartDate instead
                if let existing = testState?.preflightStartDate {
                    preflightOpenedDate = existing
                }

                // If recovered into an active prep phase, restart the monitoring timer
                if let test = testState, test.phase == .prepping {
                    prepStartTime = test.prepStartDate ?? Date()
                    startPrepMonitoring()
                }

                await refreshPreflightData()
            }
        }

        // MARK: - Actions

        /// Refresh preflight check data
        func refreshPreflightData() async {
            do {
                // Fetch glucose readings (already extracted from Core Data for thread safety)
                let readings = try await provider.fetchRecentGlucose(minutes: 45)
                let preflightReadings = readings.map { PreflightGlucoseReading(glucose: $0.glucose, direction: $0.direction) }
                let latestGlucose = readings.first?.glucose
                let latestDirection = readings.first?.direction

                await MainActor.run {
                    self.recentGlucoseValues = preflightReadings
                    self.currentGlucose = latestGlucose
                    self.currentDirection = latestDirection
                }

                // Get IOB and IOB predictions
                let iob = provider.getCurrentIOB()
                let predictions = provider.getIOBPredictions()
                await MainActor.run {
                    self.currentIOB = iob
                    self.iobPredictions = predictions
                }

                // Get COB
                let cob = try await provider.getCurrentCOB()
                await MainActor.run {
                    self.currentCOB = cob
                }

                // Get current carb ratio
                let ratio = await provider.getCurrentCarbRatio()
                await MainActor.run {
                    self.currentCarbRatio = ratio
                }

            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to fetch data: \(error.localizedDescription)"
                }
            }
        }

        /// Begin prep phase
        /// Request to begin prep - shows confirmation dialog
        func requestBeginPrep() {
            showPrepConfirmation = true
        }

        /// Confirm and begin prep phase (called after user confirms)
        func confirmBeginPrep() async {
            showPrepConfirmation = false

            // Start new test if needed
            if testState == nil {
                var newTest = calibrationService.startNewTest()
                newTest.preflightStartDate = preflightOpenedDate ?? Date()
                calibrationService.saveTestState(newTest)
            }

            // Activate calibration override (disables SMBs via the override system)
            do {
                try await calibrationService.activateCalibrationOverride()
            } catch {
                errorMessage = "Failed to activate calibration override: \(error.localizedDescription)"
                return
            }

            // Update phase
            calibrationService.updatePhase(.prepping)

            // Post Nightscout note
            calibrationService.postNightscoutNote("Carb Ratio Calibration: Prep phase started")

            // Start monitoring
            startPrepMonitoring()

            currentStep = .prep
        }

        /// Start monitoring during prep phase
        /// If `prepStartTime` is already set (e.g., from recovery), it will be preserved.
        /// Otherwise it defaults to now.
        private func startPrepMonitoring() {
            if prepStartTime == nil {
                prepStartTime = Date()
            }
            prepMonitorTimer?.invalidate()

            // Check immediately, then every 5 minutes as a background fallback
            Task { @MainActor in
                await self.checkPrepConditions()
            }
            prepMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.checkPrepConditions()
                }
            }
        }

        /// Check if prep conditions are met
        @MainActor private func checkPrepConditions() async {
            await refreshPreflightData()

            // Check timeout
            if let startTime = prepStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                let timeoutSeconds = Double(calibrationService.prepTimeoutMinutes) * 60

                if elapsed >= timeoutSeconds {
                    // Timeout - abort test
                    await handlePrepTimeout()
                    return
                }
            }

            // Check if conditions are now met
            if preflightPassed {
                // Conditions met - ready to test
                prepMonitorTimer?.invalidate()
                calibrationService.updatePhase(.readyToTest)
                calibrationService.scheduleReadyNotification()
                calibrationService.postNightscoutNote("Carb Ratio Calibration: Conditions stable, ready to test")
                currentStep = .test
            }
        }

        /// Handle prep phase timeout
        private func handlePrepTimeout() async {
            prepMonitorTimer?.invalidate()

            // Deactivate calibration override
            try? await calibrationService.deactivateCalibrationOverride()

            // Update phase
            calibrationService.updatePhase(.timedOut)

            // Post Nightscout note
            calibrationService.postNightscoutNote("Carb Ratio Calibration: Aborted (prep timeout - conditions not met)")

            // Clear test
            calibrationService.clearTest()

            errorMessage = String(
                localized: "Calibration test timed out. Conditions did not stabilize within \(calibrationService.prepTimeoutMinutes) minutes."
            )
        }

        /// Confirm tablets consumed and start test
        func confirmTabletsConsumed() {
            guard var test = testState else { return }

            // Update test state with test parameters
            test.tabletBrand = selectedBrand.rawValue
            test.tabletCount = tabletCount
            test.totalCarbs = totalCarbs
            test.carbRatioAtTestTime = currentCarbRatio
            test.bolusAmount = calculatedBolus
            test.startingGlucose = currentGlucose ?? 0
            test.startingIOB = currentIOB

            calibrationService.saveTestState(test)
            calibrationService.updatePhase(.awaitingTabletConfirmation)

            showStartTestConfirmation = true
        }

        /// Execute the calibration test bolus
        func executeTestBolus() async {
            guard let test = testState else { return }

            // Log carbs first - must succeed before bolusing
            let carbsStored = await provider.storeCalibrationCarbs(
                carbs: test.totalCarbs,
                note: "Calibration Test - \(selectedBrand.displayName) tablets"
            )

            guard carbsStored else {
                await MainActor.run {
                    errorMessage = String(localized: "Failed to log carbs. Please try again.")
                }
                return
            }

            // Execute bolus
            let success = await provider.executeCalibrationBolus(amount: test.bolusAmount)

            await MainActor.run {
                if success {
                    // Update phase - single transition to observing (bolusDelivered is implicit)
                    calibrationService.updatePhase(.observing)

                    // Post Nightscout note
                    let note =
                        "Carb Ratio Calibration: Test started (\(test.totalCarbs)g carbs, \(test.bolusAmount)U bolus, starting BG: \(test.startingGlucose))"
                    calibrationService.postNightscoutNote(note)

                    // Schedule results notification
                    let resultsTime = Date().addingTimeInterval(90 * 60)
                    calibrationService.scheduleResultsNotification(at: resultsTime)

                    currentStep = .observation
                } else {
                    errorMessage = String(localized: "Failed to deliver bolus. Please try again or cancel the test.")
                }
            }
        }

        /// Cancel the current test
        func cancelTest() async {
            prepMonitorTimer?.invalidate()

            // Deactivate calibration override
            try? await calibrationService.deactivateCalibrationOverride()

            // Cancel notifications
            calibrationService.cancelScheduledNotifications()

            // Post Nightscout note
            calibrationService.postNightscoutNote("Carb Ratio Calibration: Aborted (user cancelled)")

            // Update phase and clear
            calibrationService.updatePhase(.cancelled)
            calibrationService.clearTest()

            currentStep = .preflight
        }

        /// Complete observation and show results
        func completeObservation() async {
            await refreshPreflightData()

            guard var test = testState else { return }

            // Record ending glucose
            test.endingGlucose = currentGlucose

            // Capture full BG trace from preflight through now
            let bgStartDate = test.preflightStartDate ?? test.prepStartDate ?? test.testStartDate ?? Date()
            if let readings = try? await provider.fetchGlucoseForDateRange(from: bgStartDate, to: Date()) {
                test.glucoseReadings = readings
            }

            // Calculate results
            let (result, suggestion) = interpretResults(
                startingGlucose: test.startingGlucose,
                endingGlucose: test.endingGlucose ?? test.startingGlucose,
                currentRatio: test.carbRatioAtTestTime
            )

            test.resultInterpretation = result
            test.suggestedNewRatio = suggestion

            // Deactivate calibration override
            try? await calibrationService.deactivateCalibrationOverride()

            // Save and update phase
            calibrationService.saveTestState(test)
            calibrationService.updatePhase(.resultsReady)

            // Post Nightscout note
            let delta = (test.endingGlucose ?? 0) - test.startingGlucose
            let deltaSign = delta >= 0 ? "+" : ""
            calibrationService.postNightscoutNote(
                "Carb Ratio Calibration: Complete (BG delta: \(deltaSign)\(delta), result: \(result.displayName))"
            )

            await MainActor.run {
                self.testState = test
                self.currentStep = .results
            }
        }

        /// Apply suggested ratio
        func applySuggestedRatio(option: RatioUpdateOption) async {
            guard let suggestedRatio = testState?.suggestedNewRatio else { return }

            switch option {
            case .currentSlotOnly:
                // Find current slot index
                if let schedule = await provider.getCarbRatioSchedule() {
                    let now = Date()
                    let calendar = Calendar.current
                    let midnight = calendar.startOfDay(for: now)
                    let minutesSinceMidnight = Int(now.timeIntervalSince(midnight) / 60)

                    var currentIndex = 0
                    for (index, entry) in schedule.enumerated() {
                        if entry.offset <= minutesSinceMidnight {
                            currentIndex = index
                        }
                    }
                    await provider.updateCarbRatio(newRatio: suggestedRatio, forSlots: [currentIndex])
                }

            case .allSlots:
                await provider.updateCarbRatio(newRatio: suggestedRatio, forSlots: nil)

            case .selectSlots:
                // This would show a selection UI - for now just update current
                break
            }

            // Archive to Core Data before clearing
            if var test = testState {
                test.ratioWasApplied = true
                calibrationService.archiveCompletedTest(test, glucoseReadings: test.glucoseReadings)
            }

            // Mark as completed
            calibrationService.updatePhase(.completed)
            calibrationService.clearTest()
        }

        /// Dismiss results without applying
        func dismissResults() {
            // Archive to Core Data before clearing
            if let test = testState {
                calibrationService.archiveCompletedTest(test, glucoseReadings: test.glucoseReadings)
            }

            calibrationService.updatePhase(.completed)
            calibrationService.clearTest()
        }

        // MARK: - Results Calculation

        private func interpretResults(
            startingGlucose: Int,
            endingGlucose: Int,
            currentRatio: Decimal
        ) -> (CalibrationResult, Decimal?) {
            let delta = endingGlucose - startingGlucose

            if delta >= -20, delta <= 20 {
                return (.ratioCorrect, nil)
            } else if delta > 20 {
                // BG rose = ratio too weak = need lower g/U (more insulin per gram)
                let adjustment = calculateRatioAdjustment(delta: delta)
                let suggested = max(1, currentRatio - adjustment)
                return (.ratioTooWeak, suggested)
            } else {
                // BG dropped = ratio too strong = need higher g/U (less insulin per gram)
                let adjustment = calculateRatioAdjustment(delta: delta)
                let suggested = min(50, currentRatio + adjustment)
                return (.ratioTooStrong, suggested)
            }
        }

        private func calculateRatioAdjustment(delta: Int) -> Decimal {
            let magnitude = abs(delta)
            if magnitude > 40 {
                return 1.0
            } else if magnitude > 30 {
                return 0.75
            } else {
                return 0.5
            }
        }

        // MARK: - Step Management

        private func updateStepFromPhase() {
            guard let phase = testState?.phase else {
                currentStep = .preflight
                return
            }

            switch phase {
            case .notStarted,
                 .preflightChecking,
                 .preflightFailed,
                 .preflightPassed:
                currentStep = .preflight
            case .prepping:
                currentStep = .prep
            case .awaitingTabletConfirmation,
                 .bolusDelivered,
                 .readyToTest:
                currentStep = .test
            case .observing:
                currentStep = .observation
            case .completed,
                 .resultsReady:
                currentStep = .results
            case .cancelled,
                 .timedOut:
                currentStep = .preflight
            }
        }
    }
}
