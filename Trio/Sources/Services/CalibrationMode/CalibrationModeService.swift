import Combine
import CoreData
import Foundation
import Swinject
import UserNotifications

// MARK: - Storage Path

private enum CalibrationStorage {
    static let testStatePath = "trio/calibration_test_state.json"
    static let calibrationOverrideName = "Calibration Mode"
}

/// Service for managing carb ratio calibration tests
protocol CalibrationModeService {
    /// Current test state (nil if no active test)
    var currentTest: CalibrationTestState? { get }

    /// Publisher for test state changes
    var testStatePublisher: AnyPublisher<CalibrationTestState?, Never> { get }

    /// Load existing test from storage (e.g., after app restart)
    func loadExistingTest() -> CalibrationTestState?

    /// Start a new calibration test
    func startNewTest() -> CalibrationTestState

    /// Update the phase of the current test
    func updatePhase(_ phase: CalibrationPhase)

    /// Save the current test state
    func saveTestState(_ state: CalibrationTestState)

    /// Clear the current test (cancel or complete)
    func clearTest()

    /// Recover test state after app restart (called by StateModel when ready)
    func recoverTestStateIfNeeded() async

    /// Activate a "Calibration Mode" override that disables SMBs
    func activateCalibrationOverride() async throws

    /// Deactivate the calibration override, re-enabling normal SMB behavior
    func deactivateCalibrationOverride() async throws

    /// Timeout in minutes for prep phase (default: 60)
    var prepTimeoutMinutes: Int { get }

    /// Schedule notification for when test is ready
    func scheduleReadyNotification()

    /// Schedule notification for when results are ready
    func scheduleResultsNotification(at date: Date)

    /// Cancel all scheduled calibration notifications
    func cancelScheduledNotifications()

    /// Post a note to Nightscout about calibration status
    func postNightscoutNote(_ message: String)

    /// Archive a completed test to Core Data for historical reference
    func archiveCompletedTest(_ test: CalibrationTestState, glucoseReadings: [CalibrationGlucoseReading])
}

// MARK: - Notification Identifiers

extension BaseUserNotificationsManager.Identifier {
    static let calibrationReadyToTest = BaseUserNotificationsManager.Identifier(
        rawValue: "Trio.calibrationReadyToTest"
    )!
    static let calibrationResultsReady = BaseUserNotificationsManager.Identifier(
        rawValue: "Trio.calibrationResultsReady"
    )!
}

// MARK: - Base Implementation

final class BaseCalibrationModeService: CalibrationModeService, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var nightscoutManager: NightscoutManager!

    private let testStateSubject = CurrentValueSubject<CalibrationTestState?, Never>(nil)

    var testStatePublisher: AnyPublisher<CalibrationTestState?, Never> {
        testStateSubject.eraseToAnyPublisher()
    }

    var currentTest: CalibrationTestState? {
        testStateSubject.value
    }

    let prepTimeoutMinutes: Int = 60

    private let notificationCenter = UNUserNotificationCenter.current()

    init(resolver: Resolver) {
        injectServices(resolver)

        // Defer test recovery to avoid side effects during init
        // The StateModel will call recoverTestStateIfNeeded() when ready
    }

    /// Track whether recovery has already run this session to avoid
    /// repeated calls from subscribe() clearing an active test
    private var hasRecoveredThisSession = false

    /// Called by StateModel after initialization to recover any persisted test state
    /// This avoids side effects during service initialization
    func recoverTestStateIfNeeded() async {
        // Only run recovery once per session - subsequent subscribe() calls
        // should not re-run recovery and accidentally clear an active test
        guard !hasRecoveredThisSession else { return }
        hasRecoveredThisSession = true

        guard let existingTest = loadExistingTest() else { return }

        switch existingTest.phase {
        case .cancelled,
             .timedOut:
            // Test was aborted - deactivate override and clean up
            try? await deactivateCalibrationOverride()
            clearTest()

        case .observing:
            // Test was in observation - check if it's complete
            if let endDate = existingTest.observationEndDate, endDate <= Date() {
                // Observation period has passed - mark as ready for results
                var updatedTest = existingTest
                updatedTest.phase = .resultsReady
                testStateSubject.send(updatedTest)
                saveTestState(updatedTest)
                // Deactivate override since observation is complete
                try? await deactivateCalibrationOverride()
            } else {
                // Still observing - restore the state (override stays active in Core Data)
                testStateSubject.send(existingTest)
            }

        case .awaitingTabletConfirmation,
             .prepping,
             .readyToTest:
            // Test was in an active prep/test phase - restore state
            // The calibration override is already persisted in Core Data and stays active
            testStateSubject.send(existingTest)
            debug(.service, "CalibrationMode: Restored active test in phase: \(existingTest.phase.rawValue)")

        case .bolusDelivered:
            // Bolus was delivered but observation hasn't started yet - restore state
            // The override stays active in Core Data
            testStateSubject.send(existingTest)

        case .resultsReady:
            // Results pending review - restore state
            // Also deactivate override if it's still active (crash during completeObservation)
            try? await deactivateCalibrationOverride()
            testStateSubject.send(existingTest)

        case .completed,
             .notStarted,
             .preflightChecking,
             .preflightFailed,
             .preflightPassed:
            // Non-critical states - just restore
            testStateSubject.send(existingTest)
        }
    }

    // MARK: - Test Lifecycle

    func loadExistingTest() -> CalibrationTestState? {
        storage.retrieve(CalibrationStorage.testStatePath, as: CalibrationTestState.self)
    }

    func startNewTest() -> CalibrationTestState {
        var newTest = CalibrationTestState()
        newTest.startDate = Date()
        testStateSubject.send(newTest)
        saveTestState(newTest)
        return newTest
    }

    func updatePhase(_ phase: CalibrationPhase) {
        guard var test = currentTest else { return }
        test.phase = phase

        switch phase {
        case .prepping:
            test.prepStartDate = Date()
        case .bolusDelivered:
            test.testStartDate = Date()
        case .observing:
            if test.testStartDate == nil {
                test.testStartDate = Date()
            }
            test.observationEndDate = Date().addingTimeInterval(90 * 60) // 90 minutes
        default:
            break
        }

        testStateSubject.send(test)
        saveTestState(test)
    }

    func saveTestState(_ state: CalibrationTestState) {
        storage.save(state, as: CalibrationStorage.testStatePath)
        testStateSubject.send(state)
    }

    func clearTest() {
        storage.remove(CalibrationStorage.testStatePath)
        testStateSubject.send(nil)
    }

    // MARK: - Override Management

    func activateCalibrationOverride() async throws {
        // Disable any existing active override first
        if let existingOverrideID = try await overrideStorage.fetchLatestActiveOverride() {
            try await disableOverride(existingOverrideID)
        }

        // Create the calibration override
        let calibrationOverride = Override(
            name: CalibrationStorage.calibrationOverrideName,
            enabled: true,
            date: Date(),
            duration: 0,
            indefinite: true,
            percentage: 100,
            smbIsOff: true,
            isPreset: false,
            id: UUID().uuidString,
            overrideTarget: false,
            target: 0,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 0,
            uamMinutes: 0
        )

        try await overrideStorage.storeOverride(override: calibrationOverride)

        // Save the override ID to test state for later identification
        if var test = currentTest {
            test.calibrationOverrideID = calibrationOverride.id
            saveTestState(test)
        }

        // Trigger immediate APS loop update
        try await apsManager.determineBasalSync()

        // Notify UI to refresh override display
        await MainActor.run {
            Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
        }

        debug(.service, "CalibrationMode: Calibration override activated (SMBs disabled)")
    }

    func deactivateCalibrationOverride() async throws {
        guard let activeOverrideID = try await overrideStorage.fetchLatestActiveOverride() else {
            debug(.service, "CalibrationMode: No active override to deactivate")
            return
        }

        // Verify this is the calibration override before disabling
        let isCalibrationOverride = await isCalibrationOverride(activeOverrideID)
        guard isCalibrationOverride else {
            debug(.service, "CalibrationMode: Active override is not the calibration override - skipping deactivation")
            return
        }

        try await disableOverride(activeOverrideID)

        // Trigger immediate APS loop update
        try await apsManager.determineBasalSync()

        // Notify UI to refresh override display
        await MainActor.run {
            Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
        }

        debug(.service, "CalibrationMode: Calibration override deactivated (SMBs restored)")
    }

    /// Disable an override on a background context and create an OverrideRunStored entry
    private func disableOverride(_ objectID: NSManagedObjectID) async throws {
        let taskContext = CoreDataStack.shared.newTaskContext()
        try await taskContext.perform {
            guard let override = try taskContext.existingObject(with: objectID) as? OverrideStored else { return }

            // Create run entry to track the override's lifetime
            let run = OverrideRunStored(context: taskContext)
            run.id = UUID()
            run.name = override.name
            run.startDate = override.date ?? .distantPast
            run.endDate = Date()
            run.target = override.target ?? 0
            run.override = override
            run.isUploadedToNS = false

            // Disable the override
            override.enabled = false

            guard taskContext.hasChanges else { return }
            try taskContext.save()
        }
    }

    /// Check if the given override is the calibration override
    private func isCalibrationOverride(_ objectID: NSManagedObjectID) async -> Bool {
        let taskContext = CoreDataStack.shared.newTaskContext()
        return await taskContext.perform {
            guard let override = try? taskContext.existingObject(with: objectID) as? OverrideStored else {
                return false
            }

            // Check by name or by stored ID in test state
            if override.name == CalibrationStorage.calibrationOverrideName {
                return true
            }

            if let storedID = self.currentTest?.calibrationOverrideID,
               override.id == storedID
            {
                return true
            }

            return false
        }
    }

    // MARK: - Notifications

    func scheduleReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Ready to Test")
        content.body = String(localized: "Conditions are stable. Open Trio to start your carb ratio test.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "Trio.calibrationReadyToTest",
            content: content,
            trigger: nil // Immediate
        )

        notificationCenter.add(request) { error in
            if let error = error {
                debug(.service, "CalibrationMode: Failed to schedule ready notification: \(error)")
            }
        }
    }

    func scheduleResultsNotification(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Test Complete")
        content.body = String(localized: "Your carb ratio calibration results are ready.")
        content.sound = .default

        let timeInterval = date.timeIntervalSinceNow
        guard timeInterval > 0 else {
            // If date is in the past, send immediately
            let request = UNNotificationRequest(
                identifier: "Trio.calibrationResultsReady",
                content: content,
                trigger: nil
            )
            notificationCenter.add(request)
            return
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "Trio.calibrationResultsReady",
            content: content,
            trigger: trigger
        )

        notificationCenter.add(request) { error in
            if let error = error {
                debug(.service, "CalibrationMode: Failed to schedule results notification: \(error)")
            }
        }
    }

    func cancelScheduledNotifications() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [
            "Trio.calibrationReadyToTest",
            "Trio.calibrationResultsReady"
        ])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [
            "Trio.calibrationReadyToTest",
            "Trio.calibrationResultsReady"
        ])
    }

    // MARK: - Nightscout Integration

    func postNightscoutNote(_ message: String) {
        Task {
            await nightscoutManager.uploadNoteTreatment(note: message)
            debug(.service, "CalibrationMode: Posted Nightscout note: \(message)")
        }
    }

    // MARK: - Test History (Core Data)

    func archiveCompletedTest(_ test: CalibrationTestState, glucoseReadings: [CalibrationGlucoseReading]) {
        let taskContext = CoreDataStack.shared.newTaskContext()
        taskContext.perform {
            let stored = CalibrationTestStored(context: taskContext)
            stored.id = test.id
            stored.date = Date()
            stored.preflightStartDate = test.preflightStartDate
            stored.prepStartDate = test.prepStartDate
            stored.testStartDate = test.testStartDate
            stored.observationEndDate = test.observationEndDate
            stored.tabletBrand = test.tabletBrand
            stored.tabletCount = Int16(test.tabletCount)
            stored.totalCarbs = test.totalCarbs as NSDecimalNumber
            stored.carbRatioAtTestTime = test.carbRatioAtTestTime as NSDecimalNumber
            stored.bolusAmount = test.bolusAmount as NSDecimalNumber
            stored.startingGlucose = Int16(test.startingGlucose)
            stored.startingIOB = test.startingIOB as NSDecimalNumber
            stored.endingGlucose = Int16(test.endingGlucose ?? 0)
            stored.resultInterpretation = test.resultInterpretation?.rawValue
            stored.suggestedNewRatio = test.suggestedNewRatio.map { $0 as NSDecimalNumber }
            stored.ratioWasApplied = test.ratioWasApplied
            stored.setGlucoseReadings(glucoseReadings)

            do {
                guard taskContext.hasChanges else { return }
                try taskContext.save()
                debug(
                    .service,
                    "CalibrationMode: Archived completed test \(test.id) with \(glucoseReadings.count) glucose readings"
                )
            } catch {
                debug(.service, "CalibrationMode: Failed to archive test: \(error.localizedDescription)")
            }
        }
    }
}
