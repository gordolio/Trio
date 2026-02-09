import Combine
import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

// MARK: - Mock CalibrationModeService

/// A mock CalibrationModeService for testing without Swinject dependency injection
final class MockCalibrationModeService: CalibrationModeService {
    private let testStateSubject = CurrentValueSubject<CalibrationTestState?, Never>(nil)

    var testStatePublisher: AnyPublisher<CalibrationTestState?, Never> {
        testStateSubject.eraseToAnyPublisher()
    }

    var currentTest: CalibrationTestState? {
        testStateSubject.value
    }

    let prepTimeoutMinutes: Int = 60

    // Tracking calls for verification
    var recoverTestStateCallCount = 0
    var activateCalibrationOverrideCallCount = 0
    var deactivateCalibrationOverrideCallCount = 0
    var scheduleReadyNotificationCallCount = 0
    var scheduleResultsNotificationCallCount = 0
    var cancelScheduledNotificationsCallCount = 0
    var nightscoutNotes: [String] = []
    var phasesUpdated: [CalibrationPhase] = []
    var clearTestCallCount = 0

    // Storage for persistence simulation
    private let storage = BaseFileStorage()
    private let testFilePath = "test_mock_calibration_state"

    func loadExistingTest() -> CalibrationTestState? {
        storage.retrieve(testFilePath, as: CalibrationTestState.self)
    }

    func startNewTest() -> CalibrationTestState {
        var newTest = CalibrationTestState()
        newTest.startDate = Date()
        testStateSubject.send(newTest)
        saveTestState(newTest)
        return newTest
    }

    func updatePhase(_ phase: CalibrationPhase) {
        phasesUpdated.append(phase)
        guard var test = currentTest else { return }
        test.phase = phase

        switch phase {
        case .prepping:
            test.prepStartDate = Date()
        case .bolusDelivered:
            test.testStartDate = Date()
        case .observing:
            test.observationEndDate = Date().addingTimeInterval(90 * 60)
        default:
            break
        }

        testStateSubject.send(test)
        saveTestState(test)
    }

    func saveTestState(_ state: CalibrationTestState) {
        storage.save(state, as: testFilePath)
        testStateSubject.send(state)
    }

    func clearTest() {
        clearTestCallCount += 1
        storage.remove(testFilePath)
        testStateSubject.send(nil)
    }

    private var hasRecoveredThisSession = false

    func recoverTestStateIfNeeded() async {
        recoverTestStateCallCount += 1

        guard !hasRecoveredThisSession else { return }
        hasRecoveredThisSession = true

        guard let existingTest = loadExistingTest() else { return }

        switch existingTest.phase {
        case .cancelled,
             .timedOut:
            try? await deactivateCalibrationOverride()
            clearTest()

        case .observing:
            if let endDate = existingTest.observationEndDate, endDate <= Date() {
                var updatedTest = existingTest
                updatedTest.phase = .resultsReady
                testStateSubject.send(updatedTest)
                saveTestState(updatedTest)
                try? await deactivateCalibrationOverride()
            } else {
                testStateSubject.send(existingTest)
            }

        case .awaitingTabletConfirmation,
             .prepping,
             .readyToTest:
            // Restore active prep phases - override stays active in Core Data
            testStateSubject.send(existingTest)

        case .bolusDelivered:
            testStateSubject.send(existingTest)

        case .resultsReady:
            try? await deactivateCalibrationOverride()
            testStateSubject.send(existingTest)

        default:
            testStateSubject.send(existingTest)
        }
    }

    func activateCalibrationOverride() async throws {
        activateCalibrationOverrideCallCount += 1
    }

    func deactivateCalibrationOverride() async throws {
        deactivateCalibrationOverrideCallCount += 1
    }

    func scheduleReadyNotification() {
        scheduleReadyNotificationCallCount += 1
    }

    func scheduleResultsNotification(at _: Date) {
        scheduleResultsNotificationCallCount += 1
    }

    func cancelScheduledNotifications() {
        cancelScheduledNotificationsCallCount += 1
    }

    func postNightscoutNote(_ message: String) {
        nightscoutNotes.append(message)
    }

    /// Helper to set up a specific test state for testing
    func setTestState(_ state: CalibrationTestState) {
        testStateSubject.send(state)
        saveTestState(state)
    }

    /// Cleanup storage after tests
    func cleanup() {
        storage.remove(testFilePath)
        testStateSubject.send(nil)
        hasRecoveredThisSession = false
    }
}

// MARK: - GlucoseTabletBrand Tests

@Suite("Glucose Tablet Brand Tests") struct GlucoseTabletBrandTests {
    @Test("Dex4 has correct carbs per tablet") func testDex4CarbsPerTablet() {
        #expect(GlucoseTabletBrand.dex4.carbsPerTablet == 4)
    }

    @Test("Dex4 has correct recommended count") func testDex4RecommendedCount() {
        #expect(GlucoseTabletBrand.dex4.recommendedCount == 2)
    }

    @Test("Dex4 has correct display name") func testDex4DisplayName() {
        #expect(GlucoseTabletBrand.dex4.displayName == "Dex4")
    }

    @Test("Total carbs calculation is correct") func testTotalCarbsCalculation() {
        let brand = GlucoseTabletBrand.dex4

        #expect(brand.totalCarbs(for: 1) == 4)
        #expect(brand.totalCarbs(for: 2) == 8)
        #expect(brand.totalCarbs(for: 3) == 12)
        #expect(brand.totalCarbs(for: 0) == 0)
    }

    @Test("Bolus calculation is correct") func testBolusCalculation() {
        let brand = GlucoseTabletBrand.dex4

        // 2 tablets = 8g, ratio 10 g/U = 0.8U
        #expect(brand.bolusAmount(for: 2, carbRatio: 10) == 0.8)

        // 2 tablets = 8g, ratio 8 g/U = 1.0U
        #expect(brand.bolusAmount(for: 2, carbRatio: 8) == 1.0)

        // 3 tablets = 12g, ratio 10 g/U = 1.2U
        #expect(brand.bolusAmount(for: 3, carbRatio: 10) == 1.2)
    }

    @Test("Bolus calculation handles zero ratio") func testBolusCalculationZeroRatio() {
        let brand = GlucoseTabletBrand.dex4
        #expect(brand.bolusAmount(for: 2, carbRatio: 0) == 0)
    }

    @Test("From raw value returns correct brand") func testFromRawValue() {
        #expect(GlucoseTabletBrand.from("dex4") == .dex4)
    }

    @Test("From invalid raw value defaults to dex4") func testFromInvalidRawValue() {
        #expect(GlucoseTabletBrand.from("invalid") == .dex4)
        #expect(GlucoseTabletBrand.from("") == .dex4)
    }

    @Test("All cases are iterable") func testAllCases() {
        #expect(GlucoseTabletBrand.allCases.contains(.dex4))
        #expect(GlucoseTabletBrand.allCases.count >= 1)
    }
}

// MARK: - CalibrationTestState Tests

@Suite("Calibration Test State Tests") struct CalibrationTestStateTests {
    @Test("Default state has correct initial values") func testDefaultValues() {
        let state = CalibrationTestState()
        let defaultBrand = GlucoseTabletBrand.dex4

        #expect(state.phase == .notStarted)
        #expect(state.tabletBrand == defaultBrand.rawValue)
        #expect(state.tabletCount == defaultBrand.recommendedCount)
        #expect(state.totalCarbs == defaultBrand.totalCarbs(for: defaultBrand.recommendedCount))
        #expect(state.carbRatioAtTestTime == 0)
        #expect(state.bolusAmount == 0)
        #expect(state.startingGlucose == 0)
        #expect(state.startingIOB == 0)
        #expect(state.glucoseReadings.isEmpty)
        #expect(state.endingGlucose == nil)
        #expect(state.resultInterpretation == nil)
        #expect(state.suggestedNewRatio == nil)
    }

    @Test("Override ID defaults to nil") func testOverrideIDDefault() {
        let state = CalibrationTestState()

        #expect(state.calibrationOverrideID == nil)
    }

    @Test("State is equatable") func testEquatable() {
        var state1 = CalibrationTestState()
        var state2 = CalibrationTestState()

        // Different IDs but same data
        state1.phase = .prepping
        state2.phase = .prepping

        // They won't be equal because of different UUIDs
        #expect(state1 != state2)

        // Same state should be equal to itself
        #expect(state1 == state1)
    }

    @Test("Glucose reading can be created") func testGlucoseReading() {
        let reading = CalibrationGlucoseReading(date: Date(), glucose: 105)

        #expect(reading.glucose == 105)
    }
}

// MARK: - CalibrationPhase Tests

@Suite("Calibration Phase Tests") struct CalibrationPhaseTests {
    @Test("All phases have display names") func testDisplayNames() {
        for phase in CalibrationPhase.allCases {
            #expect(!phase.displayName.isEmpty, "Phase \(phase) should have a display name")
        }
    }

    @Test("Active phases are correctly identified") func testActivePhases() {
        // These should be active
        #expect(CalibrationPhase.prepping.isActive == true)
        #expect(CalibrationPhase.readyToTest.isActive == true)
        #expect(CalibrationPhase.awaitingTabletConfirmation.isActive == true)
        #expect(CalibrationPhase.bolusDelivered.isActive == true)
        #expect(CalibrationPhase.observing.isActive == true)

        // These should not be active
        #expect(CalibrationPhase.notStarted.isActive == false)
        #expect(CalibrationPhase.preflightChecking.isActive == false)
        #expect(CalibrationPhase.preflightFailed.isActive == false)
        #expect(CalibrationPhase.preflightPassed.isActive == false)
        #expect(CalibrationPhase.resultsReady.isActive == false)
        #expect(CalibrationPhase.completed.isActive == false)
        #expect(CalibrationPhase.cancelled.isActive == false)
        #expect(CalibrationPhase.timedOut.isActive == false)
    }

    @Test("Phase raw values are strings") func testRawValues() {
        #expect(CalibrationPhase.notStarted.rawValue == "notStarted")
        #expect(CalibrationPhase.observing.rawValue == "observing")
    }
}

// MARK: - CalibrationResult Tests

@Suite("Calibration Result Tests") struct CalibrationResultTests {
    @Test("All results have display names") func testDisplayNames() {
        #expect(!CalibrationResult.ratioCorrect.displayName.isEmpty)
        #expect(!CalibrationResult.ratioTooWeak.displayName.isEmpty)
        #expect(!CalibrationResult.ratioTooStrong.displayName.isEmpty)
    }

    @Test("All results have explanations") func testExplanations() {
        #expect(!CalibrationResult.ratioCorrect.explanation.isEmpty)
        #expect(!CalibrationResult.ratioTooWeak.explanation.isEmpty)
        #expect(!CalibrationResult.ratioTooStrong.explanation.isEmpty)
    }

    @Test("Result raw values are strings") func testRawValues() {
        #expect(CalibrationResult.ratioCorrect.rawValue == "ratioCorrect")
        #expect(CalibrationResult.ratioTooWeak.rawValue == "ratioTooWeak")
        #expect(CalibrationResult.ratioTooStrong.rawValue == "ratioTooStrong")
    }
}

// MARK: - CalibrationTestState JSON Tests

@Suite("Calibration Test State JSON Tests", .serialized) struct CalibrationTestStateJSONTests {
    let storage = BaseFileStorage()
    let testFilePath = "test_calibration_state"

    @Test("Can encode and decode test state") func testEncodeDecode() {
        // Given
        var state = CalibrationTestState()
        state.phase = .observing
        state.tabletCount = 3
        state.totalCarbs = 12
        state.carbRatioAtTestTime = 10
        state.bolusAmount = 1.2
        state.startingGlucose = 100
        state.startingIOB = 0.5
        state.calibrationOverrideID = "test-override-123"

        // When
        storage.save(state, as: testFilePath)
        let retrieved = storage.retrieve(testFilePath, as: CalibrationTestState.self)

        // Then
        #expect(retrieved != nil)
        #expect(retrieved?.phase == .observing)
        #expect(retrieved?.tabletCount == 3)
        #expect(retrieved?.totalCarbs == 12)
        #expect(retrieved?.carbRatioAtTestTime == 10)
        #expect(retrieved?.bolusAmount == 1.2)
        #expect(retrieved?.startingGlucose == 100)
        #expect(retrieved?.startingIOB == 0.5)
        #expect(retrieved?.calibrationOverrideID == "test-override-123")

        // Cleanup
        storage.remove(testFilePath)
    }

    @Test("Can encode and decode with results") func testEncodeDecodeWithResults() {
        // Given
        var state = CalibrationTestState()
        state.phase = .resultsReady
        state.endingGlucose = 115
        state.resultInterpretation = .ratioTooWeak
        state.suggestedNewRatio = 9.5

        // When
        storage.save(state, as: testFilePath)
        let retrieved = storage.retrieve(testFilePath, as: CalibrationTestState.self)

        // Then
        #expect(retrieved != nil)
        #expect(retrieved?.endingGlucose == 115)
        #expect(retrieved?.resultInterpretation == .ratioTooWeak)
        #expect(retrieved?.suggestedNewRatio == 9.5)

        // Cleanup
        storage.remove(testFilePath)
    }

    @Test("Can encode and decode with glucose readings") func testEncodeDecodeWithReadings() {
        // Given
        var state = CalibrationTestState()
        let now = Date()
        state.glucoseReadings = [
            CalibrationGlucoseReading(date: now, glucose: 100),
            CalibrationGlucoseReading(date: now.addingTimeInterval(300), glucose: 105),
            CalibrationGlucoseReading(date: now.addingTimeInterval(600), glucose: 108)
        ]

        // When
        storage.save(state, as: testFilePath)
        let retrieved = storage.retrieve(testFilePath, as: CalibrationTestState.self)

        // Then
        #expect(retrieved != nil)
        #expect(retrieved?.glucoseReadings.count == 3)
        #expect(retrieved?.glucoseReadings[0].glucose == 100)
        #expect(retrieved?.glucoseReadings[1].glucose == 105)
        #expect(retrieved?.glucoseReadings[2].glucose == 108)

        // Cleanup
        storage.remove(testFilePath)
    }
}

// MARK: - Calibration DataFlow Tests

@Suite("Calibration DataFlow Tests") struct CalibrationDataFlowTests {
    @Test("Step has correct titles") func testStepTitles() {
        #expect(!CarbRatioCalibration.Step.preflight.title.isEmpty)
        #expect(!CarbRatioCalibration.Step.prep.title.isEmpty)
        #expect(!CarbRatioCalibration.Step.test.title.isEmpty)
        #expect(!CarbRatioCalibration.Step.observation.title.isEmpty)
        #expect(!CarbRatioCalibration.Step.results.title.isEmpty)
    }

    @Test("Step has correct descriptions") func testStepDescriptions() {
        for step in CarbRatioCalibration.Step.allCases {
            #expect(!step.description.isEmpty, "Step \(step) should have a description")
        }
    }

    @Test("Step has correct icon names") func testStepIconNames() {
        #expect(CarbRatioCalibration.Step.preflight.iconName == "checklist")
        #expect(CarbRatioCalibration.Step.prep.iconName == "gearshape")
        #expect(CarbRatioCalibration.Step.test.iconName == "pill.fill")
        #expect(CarbRatioCalibration.Step.observation.iconName == "timer")
        #expect(CarbRatioCalibration.Step.results.iconName == "chart.line.uptrend.xyaxis")
    }

    @Test("Step raw values are sequential") func testStepRawValues() {
        #expect(CarbRatioCalibration.Step.preflight.rawValue == 0)
        #expect(CarbRatioCalibration.Step.prep.rawValue == 1)
        #expect(CarbRatioCalibration.Step.test.rawValue == 2)
        #expect(CarbRatioCalibration.Step.observation.rawValue == 3)
        #expect(CarbRatioCalibration.Step.results.rawValue == 4)
    }

    @Test("All steps are iterable") func testAllSteps() {
        #expect(CarbRatioCalibration.Step.allCases.count == 5)
    }

    @Test("RatioUpdateOption has correct IDs") func testRatioUpdateOptionIDs() {
        #expect(CarbRatioCalibration.RatioUpdateOption.currentSlotOnly(timeRange: "").id == "current")
        #expect(CarbRatioCalibration.RatioUpdateOption.allSlots.id == "all")
        #expect(CarbRatioCalibration.RatioUpdateOption.selectSlots.id == "select")
    }

    @Test("RatioUpdateOption has titles") func testRatioUpdateOptionTitles() {
        let currentSlot = CarbRatioCalibration.RatioUpdateOption.currentSlotOnly(timeRange: "10am-2pm")
        #expect(currentSlot.title.contains("10am-2pm"))

        #expect(!CarbRatioCalibration.RatioUpdateOption.allSlots.title.isEmpty)
        #expect(!CarbRatioCalibration.RatioUpdateOption.selectSlots.title.isEmpty)
    }
}

// MARK: - Results Interpretation Tests

@Suite("Results Interpretation Tests") struct ResultsInterpretationTests {
    @Test("Delta within tolerance is correct ratio") func testDeltaWithinTolerance() {
        // Delta of 0 (no change)
        #expect(interpretResult(startBG: 100, endBG: 100) == .ratioCorrect)

        // Delta of +15 (within +20)
        #expect(interpretResult(startBG: 100, endBG: 115) == .ratioCorrect)

        // Delta of -15 (within -20)
        #expect(interpretResult(startBG: 100, endBG: 85) == .ratioCorrect)

        // Delta of exactly +20
        #expect(interpretResult(startBG: 100, endBG: 120) == .ratioCorrect)

        // Delta of exactly -20
        #expect(interpretResult(startBG: 100, endBG: 80) == .ratioCorrect)
    }

    @Test("Delta above tolerance indicates weak ratio") func testDeltaAboveTolerance() {
        // Delta of +25 (above +20)
        #expect(interpretResult(startBG: 100, endBG: 125) == .ratioTooWeak)

        // Delta of +50 (well above tolerance)
        #expect(interpretResult(startBG: 100, endBG: 150) == .ratioTooWeak)
    }

    @Test("Delta below tolerance indicates strong ratio") func testDeltaBelowTolerance() {
        // Delta of -25 (below -20)
        #expect(interpretResult(startBG: 100, endBG: 75) == .ratioTooStrong)

        // Delta of -50 (well below tolerance)
        #expect(interpretResult(startBG: 100, endBG: 50) == .ratioTooStrong)
    }

    /// Helper to interpret results using same logic as StateModel
    private func interpretResult(startBG: Int, endBG: Int) -> CalibrationResult {
        let delta = endBG - startBG

        if delta >= -20, delta <= 20 {
            return .ratioCorrect
        } else if delta > 20 {
            return .ratioTooWeak
        } else {
            return .ratioTooStrong
        }
    }
}

// MARK: - Ratio Adjustment Calculation Tests

@Suite("Ratio Adjustment Calculation Tests") struct RatioAdjustmentTests {
    @Test("Weak ratio suggests lower value") func testWeakRatioSuggestion() {
        // Current ratio 10 g/U, BG rose significantly
        let currentRatio: Decimal = 10
        let delta = 40 // BG rose 40 mg/dL

        let adjustment = calculateAdjustment(delta: delta)
        let suggested = currentRatio - adjustment

        #expect(suggested < currentRatio, "Suggested ratio should be lower for weak ratio")
        #expect(suggested > 0, "Suggested ratio should be positive")
    }

    @Test("Strong ratio suggests higher value") func testStrongRatioSuggestion() {
        // Current ratio 10 g/U, BG dropped significantly
        let currentRatio: Decimal = 10
        let delta = -40 // BG dropped 40 mg/dL

        let adjustment = calculateAdjustment(delta: delta)
        let suggested = currentRatio + adjustment

        #expect(suggested > currentRatio, "Suggested ratio should be higher for strong ratio")
    }

    @Test("Adjustment scales with delta magnitude") func testAdjustmentScaling() {
        let smallDelta = calculateAdjustment(delta: 25)
        let mediumDelta = calculateAdjustment(delta: 35)
        let largeDelta = calculateAdjustment(delta: 50)

        #expect(smallDelta <= mediumDelta, "Larger delta should have larger adjustment")
        #expect(mediumDelta <= largeDelta, "Larger delta should have larger adjustment")
    }

    /// Helper to calculate adjustment using same logic as StateModel
    private func calculateAdjustment(delta: Int) -> Decimal {
        let magnitude = abs(delta)
        if magnitude > 40 {
            return 1.0
        } else if magnitude > 30 {
            return 0.75
        }
        return 0.5
    }
}

// MARK: - CalibrationModeService Lifecycle Tests

@Suite("Calibration Mode Service Lifecycle Tests", .serialized) struct CalibrationModeServiceLifecycleTests {
    let service = MockCalibrationModeService()

    @Test("Starting a new test creates valid state") func testStartNewTest() {
        let test = service.startNewTest()

        #expect(test.phase == .notStarted)
        #expect(test.startDate != nil)
        #expect(service.currentTest != nil)
        #expect(service.currentTest?.id == test.id)

        service.cleanup()
    }

    @Test("Updating phase transitions correctly") func testPhaseTransitions() {
        _ = service.startNewTest()

        service.updatePhase(.prepping)
        #expect(service.currentTest?.phase == .prepping)
        #expect(service.currentTest?.prepStartDate != nil)

        service.updatePhase(.readyToTest)
        #expect(service.currentTest?.phase == .readyToTest)

        service.updatePhase(.awaitingTabletConfirmation)
        #expect(service.currentTest?.phase == .awaitingTabletConfirmation)

        service.updatePhase(.observing)
        #expect(service.currentTest?.phase == .observing)
        #expect(service.currentTest?.observationEndDate != nil)

        service.updatePhase(.resultsReady)
        #expect(service.currentTest?.phase == .resultsReady)

        service.cleanup()
    }

    @Test("Clear test removes state") func testClearTest() {
        _ = service.startNewTest()
        #expect(service.currentTest != nil)

        service.clearTest()
        #expect(service.currentTest == nil)
        #expect(service.loadExistingTest() == nil)

        service.cleanup()
    }

    @Test("Save and load test state persists correctly") func testSaveLoad() {
        var state = CalibrationTestState()
        state.phase = .observing
        state.startingGlucose = 105
        state.bolusAmount = 0.8
        state.totalCarbs = 8

        service.saveTestState(state)

        let loaded = service.loadExistingTest()
        #expect(loaded != nil)
        #expect(loaded?.phase == .observing)
        #expect(loaded?.startingGlucose == 105)
        #expect(loaded?.bolusAmount == 0.8)
        #expect(loaded?.totalCarbs == 8)

        service.cleanup()
    }

    @Test("Recovery clears cancelled tests") func testRecoverCancelledTest() async {
        var state = CalibrationTestState()
        state.phase = .cancelled
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        #expect(service.currentTest == nil)
        #expect(service.deactivateCalibrationOverrideCallCount == 1)
        #expect(service.clearTestCallCount >= 1)

        service.cleanup()
    }

    @Test("Recovery clears timed out tests") func testRecoverTimedOutTest() async {
        var state = CalibrationTestState()
        state.phase = .timedOut
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        #expect(service.currentTest == nil)
        #expect(service.deactivateCalibrationOverrideCallCount == 1)

        service.cleanup()
    }

    @Test("Recovery completes expired observation") func testRecoverExpiredObservation() async {
        var state = CalibrationTestState()
        state.phase = .observing
        state.observationEndDate = Date().addingTimeInterval(-60) // Ended 1 minute ago
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        #expect(service.currentTest?.phase == .resultsReady)
        #expect(service.deactivateCalibrationOverrideCallCount == 1)

        service.cleanup()
    }

    @Test("Recovery restores ongoing observation") func testRecoverOngoingObservation() async {
        var state = CalibrationTestState()
        state.phase = .observing
        state.observationEndDate = Date().addingTimeInterval(60 * 60) // 60 min from now
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        #expect(service.currentTest?.phase == .observing)
        #expect(service.currentTest?.observationEndDate != nil)
        #expect(service.deactivateCalibrationOverrideCallCount == 0)

        service.cleanup()
    }

    @Test("Recovery restores active prep phase") func testRecoverActivePrep() async {
        var state = CalibrationTestState()
        state.phase = .prepping
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        // Active prep phases should be restored, not cleared
        #expect(service.currentTest?.phase == .prepping)
        // Override stays active in Core Data — no deactivation
        #expect(service.deactivateCalibrationOverrideCallCount == 0)

        service.cleanup()
    }

    @Test("Recovery restores active readyToTest") func testRecoverActiveReadyToTest() async {
        var state = CalibrationTestState()
        state.phase = .readyToTest
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        // Active test phases should be restored, not cleared
        #expect(service.currentTest?.phase == .readyToTest)
        // Override stays active in Core Data — no deactivation
        #expect(service.deactivateCalibrationOverrideCallCount == 0)

        service.cleanup()
    }

    @Test("Recovery restores results ready state") func testRecoverResultsReady() async {
        var state = CalibrationTestState()
        state.phase = .resultsReady
        state.endingGlucose = 130
        state.resultInterpretation = .ratioTooWeak
        state.suggestedNewRatio = 9.0
        service.setTestState(state)

        await service.recoverTestStateIfNeeded()

        #expect(service.currentTest?.phase == .resultsReady)
        #expect(service.currentTest?.endingGlucose == 130)
        #expect(service.currentTest?.suggestedNewRatio == 9.0)
        #expect(service.deactivateCalibrationOverrideCallCount == 1)

        service.cleanup()
    }

    @Test("Recovery with no existing test is a no-op") func testRecoverNoExistingTest() async {
        service.cleanup() // Ensure no state
        await service.recoverTestStateIfNeeded()

        #expect(service.currentTest == nil)
        #expect(service.deactivateCalibrationOverrideCallCount == 0)

        service.cleanup()
    }
}

// MARK: - Service Phase Tracking Tests

@Suite("Service Phase Tracking Tests", .serialized) struct ServicePhaseTrackingTests {
    let service = MockCalibrationModeService()

    @Test("Full happy path phase sequence") func testHappyPathPhaseSequence() async {
        // Start test
        _ = service.startNewTest()

        // Prep - activate override
        try? await service.activateCalibrationOverride()
        service.updatePhase(.prepping)
        #expect(service.activateCalibrationOverrideCallCount == 1)

        // Ready to test
        service.updatePhase(.readyToTest)
        service.scheduleReadyNotification()
        #expect(service.scheduleReadyNotificationCallCount == 1)

        // Tablets consumed
        service.updatePhase(.awaitingTabletConfirmation)

        // Bolus delivered & observing
        service.updatePhase(.observing)
        service.scheduleResultsNotification(at: Date().addingTimeInterval(90 * 60))
        #expect(service.scheduleResultsNotificationCallCount == 1)
        #expect(service.currentTest?.observationEndDate != nil)

        // Results - deactivate override
        service.updatePhase(.resultsReady)
        try? await service.deactivateCalibrationOverride()
        #expect(service.deactivateCalibrationOverrideCallCount == 1)

        // Complete
        service.updatePhase(.completed)
        service.clearTest()
        #expect(service.currentTest == nil)

        // Verify phase sequence
        #expect(service.phasesUpdated == [
            .prepping, .readyToTest, .awaitingTabletConfirmation, .observing, .resultsReady, .completed
        ])

        service.cleanup()
    }

    @Test("Cancellation path deactivates override") func testCancellationPath() async {
        _ = service.startNewTest()
        try? await service.activateCalibrationOverride()
        service.updatePhase(.prepping)

        // Cancel
        try? await service.deactivateCalibrationOverride()
        service.cancelScheduledNotifications()
        service.updatePhase(.cancelled)
        service.clearTest()

        #expect(service.deactivateCalibrationOverrideCallCount == 1)
        #expect(service.cancelScheduledNotificationsCallCount == 1)
        #expect(service.currentTest == nil)

        service.cleanup()
    }

    @Test("Nightscout notes are recorded") func testNightscoutNotes() {
        service.postNightscoutNote("Test started")
        service.postNightscoutNote("Test completed")

        #expect(service.nightscoutNotes.count == 2)
        #expect(service.nightscoutNotes[0] == "Test started")
        #expect(service.nightscoutNotes[1] == "Test completed")

        service.cleanup()
    }
}

// MARK: - Results Interpretation Edge Case Tests

@Suite("Results Interpretation Edge Cases") struct ResultsInterpretationEdgeCaseTests {
    /// Helper matching StateModel.interpretResults logic
    private func interpretResults(
        startingGlucose: Int,
        endingGlucose: Int,
        currentRatio: Decimal
    ) -> (CalibrationResult, Decimal?) {
        let delta = endingGlucose - startingGlucose

        if delta >= -20, delta <= 20 {
            return (.ratioCorrect, nil)
        } else if delta > 20 {
            let adjustment = calculateAdjustment(delta: delta)
            let suggested = max(1, currentRatio - adjustment)
            return (.ratioTooWeak, suggested)
        } else {
            let adjustment = calculateAdjustment(delta: delta)
            let suggested = min(50, currentRatio + adjustment)
            return (.ratioTooStrong, suggested)
        }
    }

    private func calculateAdjustment(delta: Int) -> Decimal {
        let magnitude = abs(delta)
        if magnitude > 40 {
            return 1.0
        } else if magnitude > 30 {
            return 0.75
        }
        return 0.5
    }

    @Test("Boundary delta +21 triggers weak result") func testBoundaryPositive21() {
        let (result, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 121, currentRatio: 10)
        #expect(result == .ratioTooWeak)
        #expect(suggestion != nil)
        #expect(suggestion! < 10)
    }

    @Test("Boundary delta -21 triggers strong result") func testBoundaryNegative21() {
        let (result, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 79, currentRatio: 10)
        #expect(result == .ratioTooStrong)
        #expect(suggestion != nil)
        #expect(suggestion! > 10)
    }

    @Test("Exact boundary +20 is correct") func testExactBoundaryPositive20() {
        let (result, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 120, currentRatio: 10)
        #expect(result == .ratioCorrect)
        #expect(suggestion == nil)
    }

    @Test("Exact boundary -20 is correct") func testExactBoundaryNegative20() {
        let (result, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 80, currentRatio: 10)
        #expect(result == .ratioCorrect)
        #expect(suggestion == nil)
    }

    @Test("Very low ratio doesn't go below 1") func testMinRatioClamp() {
        // With ratio 1.0 and a +50 delta, adjustment is 1.0
        // Suggested = max(1, 1.0 - 1.0) = max(1, 0) = 1
        let (result, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 150, currentRatio: 1.0)
        #expect(result == .ratioTooWeak)
        #expect(suggestion == 1)
    }

    @Test("Very high ratio doesn't exceed 50") func testMaxRatioClamp() {
        // With ratio 50.0 and a -50 delta, adjustment is 1.0
        // Suggested = min(50, 50.0 + 1.0) = min(50, 51.0) = 50
        let (result, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 50, currentRatio: 50.0)
        #expect(result == .ratioTooStrong)
        #expect(suggestion == 50)
    }

    @Test("Small delta gives small adjustment") func testSmallDeltaAdjustment() {
        // Delta of +25, adjustment should be 0.5
        let (_, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 125, currentRatio: 10)
        #expect(suggestion == 9.5) // 10 - 0.5
    }

    @Test("Medium delta gives medium adjustment") func testMediumDeltaAdjustment() {
        // Delta of +35, adjustment should be 0.75
        let (_, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 135, currentRatio: 10)
        #expect(suggestion == 9.25) // 10 - 0.75
    }

    @Test("Large delta gives large adjustment") func testLargeDeltaAdjustment() {
        // Delta of +50, adjustment should be 1.0
        let (_, suggestion) = interpretResults(startingGlucose: 100, endingGlucose: 150, currentRatio: 10)
        #expect(suggestion == 9.0) // 10 - 1.0
    }

    @Test("Zero starting glucose works") func testZeroStartingGlucose() {
        // This shouldn't happen in practice, but should not crash
        let (result, _) = interpretResults(startingGlucose: 0, endingGlucose: 100, currentRatio: 10)
        #expect(result == .ratioTooWeak) // +100 delta
    }

    @Test("Same start and end is correct") func testSameStartEnd() {
        let (result, suggestion) = interpretResults(startingGlucose: 105, endingGlucose: 105, currentRatio: 10)
        #expect(result == .ratioCorrect)
        #expect(suggestion == nil)
    }
}

// MARK: - CalibrationTestState Date Serialization Tests

@Suite("CalibrationTestState Date Serialization Tests", .serialized) struct CalibrationTestStateDateTests {
    let storage = BaseFileStorage()
    let testFilePath = "test_calibration_dates"

    @Test("Date fields survive encode/decode") func testDateSerialization() {
        var state = CalibrationTestState()
        let now = Date()
        state.startDate = now
        state.prepStartDate = now.addingTimeInterval(60)
        state.testStartDate = now.addingTimeInterval(120)
        state.observationEndDate = now.addingTimeInterval(90 * 60)

        storage.save(state, as: testFilePath)
        let retrieved = storage.retrieve(testFilePath, as: CalibrationTestState.self)

        #expect(retrieved != nil)
        // Dates may lose sub-second precision via JSON, so compare within 1 second
        #expect(abs(retrieved!.startDate!.timeIntervalSince(now)) < 1)
        #expect(abs(retrieved!.prepStartDate!.timeIntervalSince(now.addingTimeInterval(60))) < 1)
        #expect(abs(retrieved!.testStartDate!.timeIntervalSince(now.addingTimeInterval(120))) < 1)
        #expect(abs(retrieved!.observationEndDate!.timeIntervalSince(now.addingTimeInterval(90 * 60))) < 1)

        storage.remove(testFilePath)
    }

    @Test("Nil dates survive encode/decode") func testNilDateSerialization() {
        let state = CalibrationTestState()

        storage.save(state, as: testFilePath)
        let retrieved = storage.retrieve(testFilePath, as: CalibrationTestState.self)

        #expect(retrieved != nil)
        #expect(retrieved?.startDate == nil)
        #expect(retrieved?.prepStartDate == nil)
        #expect(retrieved?.testStartDate == nil)
        #expect(retrieved?.observationEndDate == nil)

        storage.remove(testFilePath)
    }

    @Test("UUID survives encode/decode") func testUUIDSerialization() {
        let state = CalibrationTestState()
        let originalID = state.id

        storage.save(state, as: testFilePath)
        let retrieved = storage.retrieve(testFilePath, as: CalibrationTestState.self)

        #expect(retrieved != nil)
        #expect(retrieved?.id == originalID)

        storage.remove(testFilePath)
    }
}

// MARK: - Observation Timing Tests

@Suite("Observation Timing Tests") struct ObservationTimingTests {
    @Test("Observation end date is 90 minutes from update") func testObservationEndDate() {
        let service = MockCalibrationModeService()
        _ = service.startNewTest()

        let beforeUpdate = Date()
        service.updatePhase(.observing)
        let afterUpdate = Date()

        let endDate = service.currentTest!.observationEndDate!
        let expectedMin = beforeUpdate.addingTimeInterval(90 * 60)
        let expectedMax = afterUpdate.addingTimeInterval(90 * 60)

        #expect(endDate >= expectedMin)
        #expect(endDate <= expectedMax)

        service.cleanup()
    }

    @Test("Prep start date is set when entering prep") func testPrepStartDate() {
        let service = MockCalibrationModeService()
        _ = service.startNewTest()

        let beforeUpdate = Date()
        service.updatePhase(.prepping)
        let afterUpdate = Date()

        let prepStart = service.currentTest!.prepStartDate!
        #expect(prepStart >= beforeUpdate)
        #expect(prepStart <= afterUpdate)

        service.cleanup()
    }

    @Test("Test start date is set when bolus delivered") func testBolusDeliveredDate() {
        let service = MockCalibrationModeService()
        _ = service.startNewTest()

        let beforeUpdate = Date()
        service.updatePhase(.bolusDelivered)
        let afterUpdate = Date()

        let testStart = service.currentTest!.testStartDate!
        #expect(testStart >= beforeUpdate)
        #expect(testStart <= afterUpdate)

        service.cleanup()
    }
}

// MARK: - Preflight Computed Property Tests

@Suite("Preflight Computed Property Logic Tests") struct PreflightComputedPropertyTests {
    // These test the same logic as the StateModel computed properties
    // without needing Swinject injection

    @Test("Glucose in range check") func testGlucoseInRange() {
        // Range is 90-120 mg/dL
        #expect(isGlucoseInRange(89) == false) // Below range
        #expect(isGlucoseInRange(90) == true) // Lower bound
        #expect(isGlucoseInRange(105) == true) // Middle
        #expect(isGlucoseInRange(120) == true) // Upper bound
        #expect(isGlucoseInRange(121) == false) // Above range
        #expect(isGlucoseInRange(nil) == false) // No glucose
    }

    @Test("IOB near zero check") func testIOBNearZero() {
        #expect(isIOBNearZero(Decimal(0)) == true)
        #expect(isIOBNearZero(Decimal(0.05)) == true)
        #expect(isIOBNearZero(Decimal(0.1)) == true) // Boundary
        #expect(isIOBNearZero(Decimal(0.11)) == false) // Just over
        #expect(isIOBNearZero(Decimal(1.0)) == false) // Well over
    }

    @Test("COB near zero check") func testCOBNearZero() {
        #expect(isCOBNearZero(Decimal(0)) == true)
        #expect(isCOBNearZero(Decimal(3)) == true)
        #expect(isCOBNearZero(Decimal(5)) == true) // Boundary
        #expect(isCOBNearZero(Decimal(6)) == false) // Just over
        #expect(isCOBNearZero(Decimal(20)) == false) // Well over
    }

    @Test("Glucose flat check requires minimum readings") func testGlucoseFlatMinimumReadings() {
        // Need at least 6 readings
        let fiveReadings = (0 ..< 5).map { _ in 100 }
        #expect(isGlucoseFlat(fiveReadings) == false)

        let sixReadings = (0 ..< 6).map { _ in 100 }
        #expect(isGlucoseFlat(sixReadings) == true)
    }

    @Test("Glucose flat with stable readings") func testGlucoseFlatStable() {
        let stableReadings = [100, 102, 101, 103, 100, 102, 101, 103, 100]
        #expect(isGlucoseFlat(stableReadings) == true)
    }

    @Test("Glucose flat with unstable readings") func testGlucoseFlatUnstable() {
        // Delta of 20 between first (newest) and last (oldest) > 15 threshold
        let unstableReadings = [120, 115, 110, 108, 105, 102, 100, 100, 100]
        #expect(isGlucoseFlat(unstableReadings) == false)
    }

    @Test("Glucose flat boundary: exactly 15 delta") func testGlucoseFlatBoundary() {
        // Delta of exactly 15 between first and last = should pass
        let boundaryReadings = [115, 112, 110, 108, 105, 102, 100, 100, 100]
        #expect(isGlucoseFlat(boundaryReadings) == true)
    }

    @Test("Glucose flat boundary: 16 delta fails") func testGlucoseFlatBoundaryFail() {
        let failReadings = [116, 112, 110, 108, 105, 102, 100, 100, 100]
        #expect(isGlucoseFlat(failReadings) == false)
    }

    @Test("Preflight passes when all conditions met") func testPreflightPassed() {
        let result = preflightPassed(
            glucose: 100,
            readings: [100, 101, 100, 101, 100, 100, 100, 101, 100],
            iob: 0.05,
            cob: 2
        )
        #expect(result == true)
    }

    @Test("Preflight fails when glucose out of range") func testPreflightFailsGlucose() {
        let result = preflightPassed(
            glucose: 80,
            readings: [100, 101, 100, 101, 100, 100, 100, 101, 100],
            iob: 0.05,
            cob: 2
        )
        #expect(result == false)
    }

    @Test("Preflight fails when IOB too high") func testPreflightFailsIOB() {
        let result = preflightPassed(
            glucose: 100,
            readings: [100, 101, 100, 101, 100, 100, 100, 101, 100],
            iob: 0.5,
            cob: 2
        )
        #expect(result == false)
    }

    // Helper functions matching StateModel logic

    private func isGlucoseInRange(_ glucose: Int?) -> Bool {
        guard let bg = glucose else { return false }
        return bg >= 90 && bg <= 120
    }

    private func isIOBNearZero(_ iob: Decimal) -> Bool {
        iob <= 0.1
    }

    private func isCOBNearZero(_ cob: Decimal) -> Bool {
        cob <= 5
    }

    private func isGlucoseFlat(_ readings: [Int]) -> Bool {
        guard readings.count >= 6 else { return false }
        let subset = Array(readings.prefix(9))
        guard let newest = subset.first, let oldest = subset.last else { return false }
        return abs(newest - oldest) <= 15
    }

    private func preflightPassed(glucose: Int?, readings: [Int], iob: Decimal, cob: Decimal) -> Bool {
        isGlucoseInRange(glucose) && isGlucoseFlat(readings) && isIOBNearZero(iob) && isCOBNearZero(cob)
    }
}

// MARK: - Bolus Calculation Tests

@Suite("Bolus Calculation Tests") struct BolusCalculationTests {
    @Test("Bolus with various ratios") func testBolusVariousRatios() {
        let brand = GlucoseTabletBrand.dex4

        // 2 tablets (8g) with different ratios
        #expect(brand.bolusAmount(for: 2, carbRatio: 5) == 1.6) // 8/5
        #expect(brand.bolusAmount(for: 2, carbRatio: 10) == 0.8) // 8/10
        #expect(brand.bolusAmount(for: 2, carbRatio: 20) == 0.4) // 8/20
        #expect(brand.bolusAmount(for: 2, carbRatio: 40) == 0.2) // 8/40
    }

    @Test("Bolus with negative count gives negative (edge case)") func testBolusNegativeCount() {
        let brand = GlucoseTabletBrand.dex4
        // This shouldn't happen via UI (stepper minimum is 1) but shouldn't crash
        let result = brand.bolusAmount(for: -1, carbRatio: 10)
        #expect(result == -0.4) // -4/10
    }

    @Test("Bolus with very small ratio") func testBolusSmallRatio() {
        let brand = GlucoseTabletBrand.dex4
        // Very small ratio = very large bolus (dangerous, but calculation should be correct)
        let result = brand.bolusAmount(for: 2, carbRatio: 1)
        #expect(result == 8) // 8/1
    }

    @Test("Bolus with very large ratio") func testBolusLargeRatio() {
        let brand = GlucoseTabletBrand.dex4
        let result = brand.bolusAmount(for: 2, carbRatio: 50)
        #expect(result == 0.16) // 8/50
    }

    @Test("Total carbs scales linearly with count") func testTotalCarbsLinear() {
        let brand = GlucoseTabletBrand.dex4
        for count in 1 ... 4 {
            #expect(brand.totalCarbs(for: count) == Decimal(count) * brand.carbsPerTablet)
        }
    }
}

// MARK: - Step-to-Phase Mapping Tests

@Suite("Step-to-Phase Mapping Tests") struct StepToPhaseMappingTests {
    /// This tests the same logic as StateModel.updateStepFromPhase()
    private func stepFromPhase(_ phase: CalibrationPhase?) -> CarbRatioCalibration.Step {
        guard let phase = phase else { return .preflight }

        switch phase {
        case .notStarted,
             .preflightChecking,
             .preflightFailed,
             .preflightPassed:
            return .preflight
        case .prepping:
            return .prep
        case .awaitingTabletConfirmation,
             .bolusDelivered,
             .readyToTest:
            return .test
        case .observing:
            return .observation
        case .completed,
             .resultsReady:
            return .results
        case .cancelled,
             .timedOut:
            return .preflight
        }
    }

    @Test("Nil phase maps to preflight") func testNilPhase() {
        #expect(stepFromPhase(nil) == .preflight)
    }

    @Test("All preflight-related phases map to preflight step") func testPreflightPhases() {
        #expect(stepFromPhase(.notStarted) == .preflight)
        #expect(stepFromPhase(.preflightChecking) == .preflight)
        #expect(stepFromPhase(.preflightFailed) == .preflight)
        #expect(stepFromPhase(.preflightPassed) == .preflight)
    }

    @Test("Prepping maps to prep step") func testPrepPhase() {
        #expect(stepFromPhase(.prepping) == .prep)
    }

    @Test("Test-related phases map to test step") func testTestPhases() {
        #expect(stepFromPhase(.readyToTest) == .test)
        #expect(stepFromPhase(.awaitingTabletConfirmation) == .test)
        #expect(stepFromPhase(.bolusDelivered) == .test)
    }

    @Test("Observing maps to observation step") func testObservingPhase() {
        #expect(stepFromPhase(.observing) == .observation)
    }

    @Test("Results phases map to results step") func testResultsPhases() {
        #expect(stepFromPhase(.resultsReady) == .results)
        #expect(stepFromPhase(.completed) == .results)
    }

    @Test("Terminal phases map back to preflight step") func testTerminalPhases() {
        #expect(stepFromPhase(.cancelled) == .preflight)
        #expect(stepFromPhase(.timedOut) == .preflight)
    }

    @Test("Every CalibrationPhase maps to a valid step") func testAllPhasesCovered() {
        for phase in CalibrationPhase.allCases {
            let step = stepFromPhase(phase)
            #expect(CarbRatioCalibration.Step.allCases.contains(step), "Phase \(phase) should map to a valid step")
        }
    }
}

// MARK: - Ratio Clamping Tests

@Suite("Ratio Clamping Tests") struct RatioClampingTests {
    /// Matches Provider.clampRatio logic
    private func clampRatio(_ ratio: Decimal) -> Decimal {
        min(max(ratio, 1), 50)
    }

    @Test("Ratio within bounds is unchanged") func testWithinBounds() {
        #expect(clampRatio(10) == 10)
        #expect(clampRatio(1) == 1) // Lower bound
        #expect(clampRatio(50) == 50) // Upper bound
        #expect(clampRatio(25.5) == 25.5)
    }

    @Test("Ratio below minimum is clamped to 1") func testBelowMinimum() {
        #expect(clampRatio(0.5) == 1)
        #expect(clampRatio(0) == 1)
        #expect(clampRatio(-5) == 1)
    }

    @Test("Ratio above maximum is clamped to 50") func testAboveMaximum() {
        #expect(clampRatio(51) == 50)
        #expect(clampRatio(100) == 50)
    }
}

// MARK: - Publisher Tests

@Suite("CalibrationModeService Publisher Tests") struct CalibrationPublisherTests {
    @Test("Test state publisher emits on phase changes") func testPublisherEmitsOnPhaseChange() async {
        let service = MockCalibrationModeService()
        var receivedStates: [CalibrationPhase?] = []
        var cancellables = Set<AnyCancellable>()

        service.testStatePublisher
            .sink { state in
                receivedStates.append(state?.phase)
            }
            .store(in: &cancellables)

        _ = service.startNewTest()
        service.updatePhase(.prepping)
        service.updatePhase(.readyToTest)

        // Give publisher time to emit
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        #expect(receivedStates.count >= 3)

        service.cleanup()
        cancellables.removeAll()
    }

    @Test("Test state publisher emits nil on clear") func testPublisherEmitsNilOnClear() async {
        let service = MockCalibrationModeService()
        var lastState: CalibrationTestState?? = .some(CalibrationTestState()) // Non-nil initial
        var cancellables = Set<AnyCancellable>()

        service.testStatePublisher
            .sink { state in
                lastState = state
            }
            .store(in: &cancellables)

        _ = service.startNewTest()
        service.clearTest()

        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(lastState == CalibrationTestState??.some(nil))

        service.cleanup()
        cancellables.removeAll()
    }
}

// MARK: - Integration Tests: StateModel Initialization (Crash Reproduction)

@Suite("CarbRatioCalibration Integration Tests", .serialized) struct CarbRatioCalibrationIntegrationTests: Injectable {
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        // Set up the full DI container, just like the app does on launch.
        // This reproduces the exact initialization path that happens when navigating
        // to the CarbRatioCalibration screen.
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    @Test("StateModel can be created without crash") func testStateModelCreation() {
        // This is the first thing that happens in the RootView:
        // @StateObject var state = StateModel()
        let stateModel = CarbRatioCalibration.StateModel()
        #expect(stateModel.currentStep == .preflight)
        #expect(stateModel.testState == nil)
        #expect(stateModel.currentGlucose == nil)
        #expect(stateModel.errorMessage == nil)
    }

    @Test("StateModel survives resolver assignment (configureView path)") func testStateModelResolverAssignment() {
        // This reproduces what configureView() does:
        // state.resolver = resolver
        // Which triggers: injectServices(resolver) -> Provider(resolver:) -> subscribe()
        let stateModel = CarbRatioCalibration.StateModel()

        // This is THE critical line that crashes when navigating.
        // It triggers the full DI resolution chain.
        stateModel.resolver = resolver

        // If we get here without crashing, the initialization path works
        #expect(stateModel.currentStep == .preflight)
    }

    @Test("Provider can be created without crash") func testProviderCreation() {
        // The Provider is created inside BaseStateModel.resolver.didSet:
        // provider = Provider(resolver: resolver)
        // The Provider init calls injectServices(resolver) and creates a CoreData context.
        let provider = CarbRatioCalibration.Provider(resolver: resolver)
        #expect(provider != nil)
    }

    @Test("StateModel subscribe() executes without crash") func testStateModelSubscribe() async {
        // subscribe() is called after provider creation and calls:
        // 1. calibrationService.recoverTestStateIfNeeded()
        // 2. calibrationService.testStatePublisher subscription
        // 3. refreshPreflightData() (async)
        let stateModel = CarbRatioCalibration.StateModel()
        stateModel.resolver = resolver

        // Give subscribe's async work time to complete
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // subscribe() should have run without crash
        #expect(stateModel.currentStep == .preflight)
    }

    @Test("Full configureView simulation") func testFullConfigureViewSimulation() {
        // Simulates exactly what happens when the view appears:
        // 1. StateModel is created (via @StateObject)
        // 2. configureView() checks state.isInitial
        // 3. Sets state.resolver = resolver (triggers DI + subscribe)
        // 4. Sets state.isInitial = false
        let stateModel = CarbRatioCalibration.StateModel()

        #expect(stateModel.isInitial == true)

        if stateModel.isInitial {
            stateModel.resolver = resolver
            stateModel.isInitial = false
        }

        #expect(stateModel.isInitial == false)
        #expect(stateModel.currentStep == .preflight)
    }

    @Test("Screen.carbRatioCalibration view creation") func testScreenViewCreation() {
        // This tests the Screen enum's view builder, which is what the Router calls
        // when navigating to the screen
        let screen = Screen.carbRatioCalibration
        #expect(screen.id != 0)
    }

    @Test("Provider fetchRecentGlucose doesn't crash on empty database") func testProviderFetchRecentGlucose() async throws {
        let provider = CarbRatioCalibration.Provider(resolver: resolver)
        let readings = try await provider.fetchRecentGlucose(minutes: 45)
        #expect(readings.isEmpty) // No data in test database
    }

    @Test("Provider getCurrentIOB doesn't crash") func testProviderGetCurrentIOB() {
        let provider = CarbRatioCalibration.Provider(resolver: resolver)
        let iob = provider.getCurrentIOB()
        // Should return 0 or some value without crashing
        #expect(iob >= 0 || iob < 0) // Just verify no crash
    }

    @Test("Provider getCurrentCOB doesn't crash on empty database") func testProviderGetCurrentCOB() async throws {
        let provider = CarbRatioCalibration.Provider(resolver: resolver)
        let cob = try await provider.getCurrentCOB()
        #expect(cob == 0) // No determinations in test database
    }

    @Test("Provider getCurrentCarbRatio returns a positive value") func testProviderGetCurrentCarbRatio() async {
        let provider = CarbRatioCalibration.Provider(resolver: resolver)
        let ratio = await provider.getCurrentCarbRatio()
        // Returns stored value or default fallback (10) - should always be positive
        #expect(ratio > 0, "Carb ratio should be positive")
        #expect(ratio <= 50, "Carb ratio should be within safe bounds")
    }

    @Test("StateModel refreshPreflightData doesn't crash") func testRefreshPreflightData() async {
        let stateModel = CarbRatioCalibration.StateModel()
        stateModel.resolver = resolver

        // Wait for initial subscribe's async work
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Call refreshPreflightData explicitly
        await stateModel.refreshPreflightData()

        // Should complete without crash
        #expect(stateModel.currentStep == .preflight)
    }

    @Test("CalibrationModeService resolves correctly") func testCalibrationModeServiceResolution() {
        let service = resolver.resolve(CalibrationModeService.self)
        #expect(service != nil, "CalibrationModeService should be registered in ServiceAssembly")
    }

    @Test("IOBService resolves correctly") func testIOBServiceResolution() {
        let service = resolver.resolve(IOBService.self)
        #expect(service != nil, "IOBService should be registered in ServiceAssembly")
    }

    @Test("All StateModel dependencies resolve") func testAllDependenciesResolve() {
        // Verify every service that StateModel and Provider need is registered
        #expect(resolver.resolve(CalibrationModeService.self) != nil, "CalibrationModeService")
        #expect(resolver.resolve(IOBService.self) != nil, "IOBService")
        #expect(resolver.resolve(Router.self) != nil, "Router")
        #expect(resolver.resolve(SettingsManager.self) != nil, "SettingsManager")
        #expect(resolver.resolve(DeviceDataManager.self) != nil, "DeviceDataManager")
        #expect(resolver.resolve(FileStorage.self) != nil, "FileStorage")
        #expect(resolver.resolve(BluetoothStateManager.self) != nil, "BluetoothStateManager")
        #expect(resolver.resolve(DeterminationStorage.self) != nil, "DeterminationStorage")
        #expect(resolver.resolve(CarbsStorage.self) != nil, "CarbsStorage")
        #expect(resolver.resolve(APSManager.self) != nil, "APSManager")
    }
}

// MARK: - Tablet Effect Math Tests

@Suite("Glucose Tablet Simulation", .serialized) struct GlucoseTabletSimulationTests {
    /// Helper: create a fresh OscillatingGenerator with clean UserDefaults state.
    /// Must run serialized because OscillatingGenerator reads from shared UserDefaults.
    private func makeCleanGenerator() -> OscillatingGenerator {
        // Clear ALL tablet-related UserDefaults to ensure clean state
        UserDefaults.standard.set(0.0, forKey: "GlucoseSimulator_TabletTakenDate")
        UserDefaults.standard.removeObject(forKey: "GlucoseSimulator_TabletTargetDelta")
        UserDefaults.standard.synchronize()
        return OscillatingGenerator()
    }

    @Test("tabletEffect returns 0 when no tablet is active") func testNoTabletReturnsZero() {
        let gen = makeCleanGenerator()
        #expect(gen.tabletTakenDate == nil, "Precondition: no tablet should be set")
        let effect = gen.tabletEffect(at: Date())
        #expect(effect == 0, "No tablet taken — effect should be 0")
    }

    @Test(
        "tabletEffect returns exactly targetDelta at 90 minutes for positive delta"
    ) func testTabletEffectAtNinetyMinutesPositive() {
        let gen = makeCleanGenerator()
        let tabletTime = Date()
        gen.tabletTakenDate = tabletTime
        gen.tabletTargetDelta = 25.0

        let ninetyMinLater = tabletTime.addingTimeInterval(5400)
        let effect = gen.tabletEffect(at: ninetyMinLater)

        // Should be exactly 25.0 (within floating point precision)
        #expect(abs(effect - 25.0) < 0.001, "Effect at 90 min should equal targetDelta (+25)")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test(
        "tabletEffect returns exactly targetDelta at 90 minutes for negative delta"
    ) func testTabletEffectAtNinetyMinutesNegative() {
        let gen = makeCleanGenerator()
        let tabletTime = Date()
        gen.tabletTakenDate = tabletTime
        gen.tabletTargetDelta = -25.0

        let ninetyMinLater = tabletTime.addingTimeInterval(5400)
        let effect = gen.tabletEffect(at: ninetyMinLater)

        #expect(abs(effect - (-25.0)) < 0.001, "Effect at 90 min should equal targetDelta (-25)")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("tabletEffect returns 0 at t=0 and ~0 at 90 min when targetDelta is 0") func testTabletEffectZeroDelta() {
        let gen = makeCleanGenerator()
        gen.tabletTakenDate = Date()
        gen.tabletTargetDelta = 0.0

        let tabletTime = gen.tabletTakenDate!
        // At t=0 both curves are 0
        #expect(gen.tabletEffect(at: tabletTime.addingTimeInterval(0)) == 0)
        // At 90 min the two curves are calibrated to match, so net effect ≈ 0
        #expect(abs(gen.tabletEffect(at: tabletTime.addingTimeInterval(5400))) < 0.001)
        // At intermediate times the carb and insulin curves have different shapes,
        // so the net effect won't be exactly 0 — but it should be bounded
        let at24min = gen.tabletEffect(at: tabletTime.addingTimeInterval(1440))
        #expect(abs(at24min) < 250, "Transient imbalance at 24 min should be bounded")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("tabletEffect returns 0 after 120 minutes (cutoff)") func testTabletEffectAfterCutoff() {
        let gen = makeCleanGenerator()
        let tabletTime = Date()
        gen.tabletTakenDate = tabletTime
        gen.tabletTargetDelta = 25.0

        // Use 7201s (not 7200) to avoid floating-point boundary from UserDefaults round-trip
        let afterCutoff = tabletTime.addingTimeInterval(7201)
        let effect = gen.tabletEffect(at: afterCutoff)
        #expect(effect == 0, "Effect should be 0 after 120 min cutoff")

        let wellAfter = tabletTime.addingTimeInterval(10000)
        let effectLater = gen.tabletEffect(at: wellAfter)
        #expect(effectLater == 0, "Effect should be 0 well after cutoff")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("tabletEffect peaks around 24 minutes") func testTabletEffectPeaksAround24Min() {
        let gen = makeCleanGenerator()
        let tabletTime = Date()
        gen.tabletTakenDate = tabletTime
        gen.tabletTargetDelta = 25.0

        // Sample at several time points
        let at10min = gen.tabletEffect(at: tabletTime.addingTimeInterval(600))
        let at24min = gen.tabletEffect(at: tabletTime.addingTimeInterval(1440))
        let at40min = gen.tabletEffect(at: tabletTime.addingTimeInterval(2400))
        let at90min = gen.tabletEffect(at: tabletTime.addingTimeInterval(5400))

        // Peak should be higher than surrounding values
        #expect(at24min > at10min, "Peak at 24 min should be higher than at 10 min")
        #expect(at24min > at40min, "Peak at 24 min should be higher than at 40 min")
        #expect(at24min > at90min, "Peak at 24 min should be higher than at 90 min")

        // Peak should be significantly higher than target delta
        // The carb curve dominates early (fast absorption) while insulin is slower,
        // producing a peak around 200 mg/dL for a 25 mg/dL target delta
        #expect(at24min > 50, "Peak should be well above the 25 mg/dL target")
        #expect(at24min < 300, "Peak should be bounded")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("tabletEffect is 0 at t=0 (tablet just taken)") func testTabletEffectAtTimeZero() {
        let gen = makeCleanGenerator()
        let tabletTime = Date()
        gen.tabletTakenDate = tabletTime
        gen.tabletTargetDelta = 25.0

        let effect = gen.tabletEffect(at: tabletTime)
        #expect(abs(effect) < 0.001, "Effect should be ~0 at the moment the tablet is taken")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("tabletEffect is 0 before tablet was taken") func testTabletEffectBeforeTabletTaken() {
        let gen = makeCleanGenerator()
        let tabletTime = Date()
        gen.tabletTakenDate = tabletTime
        gen.tabletTargetDelta = 25.0

        let beforeTablet = tabletTime.addingTimeInterval(-300)
        let effect = gen.tabletEffect(at: beforeTablet)
        #expect(effect == 0, "Effect should be 0 before the tablet was taken")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("simulateTablet sets tabletTakenDate to now") func testSimulateTablet() {
        let gen = makeCleanGenerator()
        #expect(gen.tabletTakenDate == nil)

        let before = Date()
        gen.simulateTablet()
        let after = Date()

        #expect(gen.tabletTakenDate != nil, "tabletTakenDate should be set")
        // Allow tiny tolerance for Date→Double→Date round-trip through UserDefaults
        let tolerance: TimeInterval = 0.001
        #expect(
            gen.tabletTakenDate!.timeIntervalSince1970 >= before.timeIntervalSince1970 - tolerance,
            "tabletTakenDate should be around the time simulateTablet was called"
        )
        #expect(
            gen.tabletTakenDate!.timeIntervalSince1970 <= after.timeIntervalSince1970 + tolerance,
            "tabletTakenDate should be before return"
        )

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("isTabletActive reflects active state") func testIsTabletActive() {
        let gen = makeCleanGenerator()
        #expect(!gen.isTabletActive, "Should not be active without a tablet")

        gen.simulateTablet()
        #expect(gen.isTabletActive, "Should be active right after taking tablet")

        // Simulate expired tablet (> 120 min ago)
        gen.tabletTakenDate = Date().addingTimeInterval(-7201)
        #expect(!gen.isTabletActive, "Should not be active after 120 min")

        // Cleanup
        gen.tabletTakenDate = nil
    }

    @Test("resetToDefaults clears tablet state") func testResetClearsTablet() {
        let gen = makeCleanGenerator()
        gen.simulateTablet()
        gen.tabletTargetDelta = -30.0

        gen.resetToDefaults()

        #expect(gen.tabletTakenDate == nil, "Tablet date should be cleared")
        #expect(gen.tabletTargetDelta == OscillatingGenerator.Defaults.tabletTargetDelta, "Delta should return to default")
    }

    @Test("tabletTargetDelta handles 0 as a valid value") func testZeroDeltaNotConfusedWithUnset() {
        let gen = makeCleanGenerator()

        // Explicitly set to 0 (the "ratio correct" scenario)
        gen.tabletTargetDelta = 0.0

        #expect(gen.tabletTargetDelta == 0.0, "Should read back 0.0 (not the default 25.0)")

        // Cleanup — remove so other tests get default
        UserDefaults.standard.removeObject(forKey: "GlucoseSimulator_TabletTargetDelta")
    }
}
