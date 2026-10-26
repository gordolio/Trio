import Combine
import Foundation
import LoopKit
import Swinject
import Testing

@testable import Trio

// MARK: - Basal test evaluation

@Suite("Basal test evaluator") struct BasalTestEvaluatorTests {
    private let hour: TimeInterval = 3600

    private func evaluate(
        start: Int = 100,
        end: Int,
        elapsedHours: Double = 4,
        plannedHours: Double = 4,
        reason: BasalTestEndReason = .completed,
        interference: String? = nil
    ) -> BasalTestEvaluator.Evaluation {
        BasalTestEvaluator.evaluate(
            startGlucose: start,
            endGlucose: end,
            elapsed: elapsedHours * hour,
            planned: plannedHours * hour,
            reason: reason,
            interference: interference
        )
    }

    @Test("Glucose that barely moves is steady") func steady() {
        let result = evaluate(end: 110)
        #expect(result.outcome == .steady)
        #expect(result.direction == .keep)
        #expect(result.netChange == 10)
    }

    @Test("A change exactly at the tolerance is still steady") func toleranceIsInclusive() {
        #expect(evaluate(end: 120).outcome == .steady)
        #expect(evaluate(end: 80).outcome == .steady)
    }

    @Test("A rise beyond the tolerance says basal is too low") func rising() {
        let result = evaluate(end: 121)
        #expect(result.outcome == .rising)
        #expect(result.direction == .increase)
    }

    @Test("A fall beyond the tolerance says basal is too high") func falling() {
        let result = evaluate(end: 79)
        #expect(result.outcome == .falling)
        #expect(result.direction == .decrease)
    }

    @Test("Ending a low is a fall even when the net change is small") func lowEnds() {
        let result = evaluate(start: 95, end: 68, elapsedHours: 1, reason: .low)
        #expect(result.outcome == .falling)
        #expect(result.direction == .decrease)
    }

    @Test("Ending early with little change is inconclusive") func earlyIsInconclusive() {
        let result = evaluate(end: 110, elapsedHours: 2, reason: .endedEarly)
        #expect(result.outcome == .inconclusive)
        #expect(result.direction == nil)
    }

    @Test("Ending early after a big drift is already clear") func earlyButClear() {
        let result = evaluate(end: 150, elapsedHours: 2, reason: .endedEarly)
        #expect(result.outcome == .rising)
    }

    @Test("Three quarters of the planned time is enough") func threeQuarters() {
        #expect(evaluate(end: 130, elapsedHours: 3, reason: .endedEarly).outcome == .rising)
        #expect(evaluate(end: 130, elapsedHours: 2.9, reason: .endedEarly).outcome == .inconclusive)
    }

    @Test("Carbs or a bolus during the fast invalidate it, whatever glucose did") func interrupted() {
        let result = evaluate(end: 200, interference: "Carbs were logged during the fast.")
        #expect(result.outcome == .invalid)
        #expect(result.direction == nil)
        #expect(evaluate(end: 200, reason: .interrupted).outcome == .invalid)
    }

    @Test("Only steady, rising and falling say anything about basal") func conclusive() {
        #expect(BasalTestOutcome.steady.isConclusive)
        #expect(BasalTestOutcome.rising.isConclusive)
        #expect(BasalTestOutcome.falling.isConclusive)
        #expect(!BasalTestOutcome.inconclusive.isConclusive)
        #expect(!BasalTestOutcome.invalid.isConclusive)
    }

    @Test("End glucose averages the last three readings") func endGlucoseAverages() {
        let now = Date()
        let readings = (0 ..< 6).map { BasalTestReading(date: now.addingTimeInterval(Double($0) * 300), glucose: 100 + $0 * 10) }
        // Last three are 130, 140, 150.
        #expect(BasalTestEvaluator.endGlucose(from: readings, fallback: 0) == 140)
    }

    @Test("End glucose falls back when there are no readings") func endGlucoseFallback() {
        #expect(BasalTestEvaluator.endGlucose(from: [], fallback: 97) == 97)
    }

    @Test("Time blocks follow the hour a test starts") func timeBlocks() {
        let calendar = Calendar(identifier: .gregorian)
        func block(_ hour: Int) -> String {
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: hour))!
            return BasalTestEvaluator.timeBlock(for: date, calendar: calendar)
        }
        #expect(block(2) == String(localized: "Overnight"))
        #expect(block(6) == String(localized: "Morning"))
        #expect(block(12) == String(localized: "Afternoon"))
        #expect(block(19) == String(localized: "Evening"))
        #expect(block(23) == String(localized: "Overnight"))
    }

    @Test("State survives a round trip through JSON") func stateRoundTrip() throws {
        var state = BasalTestState(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            plannedDuration: 4 * hour,
            startGlucose: 105,
            startIOB: 0.1,
            previousMode: .closed,
            timeBlock: "Overnight"
        )
        state.phase = .finished
        state.endReason = .completed
        state.outcome = .steady
        state.readings = [BasalTestReading(date: Date(timeIntervalSince1970: 1_000_300), glucose: 108)]

        let data = try JSONCoding.encoder.encode(state)
        let decoded = try JSONCoding.decoder.decode(BasalTestState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.plannedEnd == state.startedAt.addingTimeInterval(4 * hour))
    }
}

// MARK: - Settings test service

/// A settings manager that keeps everything in memory.
private final class FakeSettingsManager: SettingsManager {
    var settings = TrioSettings()
    var preferences = Preferences()
    var pumpSettings = PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2)
    func updateInsulinCurve(_: InsulinType?) {}
}

@Suite("Settings test service", .serialized) struct SettingsTestServiceTests {
    private let sessionPath = "trio/settings_test_session.json"
    private let historyPath = "trio/settings_test_history.json"

    private func makeService(
        mode: DosingMode,
        existing: SettingsTestSession? = nil
    ) -> (BaseSettingsTestService, FakeSettingsManager, FileStorage) {
        let storage = BaseFileStorage()
        storage.remove(sessionPath)
        storage.remove(historyPath)
        if let existing { storage.save(existing, as: sessionPath) }

        let settings = FakeSettingsManager()
        settings.settings.dosingMode = mode

        let container = Container()
        container.register(FileStorage.self) { _ in storage }
        container.register(SettingsManager.self) { _ in settings }
        return (BaseSettingsTestService(resolver: container), settings, storage)
    }

    private func cleanUp(_ storage: FileStorage) {
        storage.remove(sessionPath)
        storage.remove(historyPath)
    }

    private func record(minutesAgo: Int, kind: SettingsTestKind = .basal) -> SettingsTestRecord {
        let end = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        return SettingsTestRecord(
            kind: kind,
            startedAt: end.addingTimeInterval(-4 * 3600),
            completedAt: end,
            timeBlock: "Overnight",
            startGlucose: 100,
            endGlucose: 105,
            direction: .keep,
            summary: "steady"
        )
    }

    @Test("Ending a test puts the previous dosing mode back") func restoresMode() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        settings.settings.dosingMode = .basalTesting
        #expect(service.activeSession != nil)

        service.end()
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.activeSession == nil)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
    }

    @Test("A mode the user chose themselves is left alone") func leavesUserChoice() {
        let (service, settings, storage) = makeService(mode: .lowGlucoseSuspend)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        service.end()
        #expect(settings.settings.dosingMode == .lowGlucoseSuspend)
    }

    @Test("A session that ran past its deadline is closed on launch") func expiredSessionRestoresOnLaunch() {
        let stale = SettingsTestSession(
            kind: .basal,
            startedAt: Date().addingTimeInterval(-6 * 3600),
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: stale)
        defer { cleanUp(storage) }

        #expect(settings.settings.dosingMode == .closed)
        #expect(service.activeSession == nil)
    }

    @Test("A session still inside its deadline survives a relaunch") func liveSessionSurvivesLaunch() {
        let live = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: live)
        defer { cleanUp(storage) }

        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.activeSession?.id == live.id)
    }

    @Test("endIfExpired leaves a running session alone") func notExpiredNoOp() {
        let (service, settings, storage) = makeService(mode: .basalTesting)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        service.endIfExpired()
        #expect(service.activeSession != nil)
        #expect(settings.settings.dosingMode == .basalTesting)
    }

    @Test("Ending with no session does nothing") func endWithoutSession() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.end()
        #expect(settings.settings.dosingMode == .closed)
    }

    @Test("History comes back newest first and can be filtered") func historyOrderAndFilter() {
        let (service, _, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.archive(record(minutesAgo: 300))
        service.archive(record(minutesAgo: 10))
        service.archive(record(minutesAgo: 100, kind: .carbRatio))

        let all = service.history(for: nil)
        #expect(all.count == 3)
        #expect(all.map(\.kind) == [.basal, .carbRatio, .basal])

        let basal = service.history(for: .basal)
        #expect(basal.count == 2)
        #expect(basal[0].completedAt > basal[1].completedAt)
    }

    @Test("History keeps only the most recent records") func historyIsCapped() {
        let (service, _, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        for minutes in 0 ..< 205 {
            service.archive(record(minutesAgo: minutes))
        }
        #expect(service.history(for: nil).count == 200)
    }
}

@Suite("Settings test kinds") struct SettingsTestKindTests {
    @Test("Basal is listed before sensitivity, then carb ratio") func order() {
        #expect(SettingsTestKind.allCases == [.basal, .isf, .carbRatio])
    }

    @Test("Only tests with a wizard are available") func availability() {
        #expect(SettingsTestKind.basal.isAvailable)
        #expect(SettingsTestKind.carbRatio.isAvailable)
        #expect(!SettingsTestKind.isf.isAvailable)
    }

    @Test("Sessions and records round trip through JSON") func roundTrip() throws {
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: Date(timeIntervalSince1970: 1_900_000),
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            restore: [.dosingMode(testMode: .basalTesting, previous: .lowGlucoseSuspend)]
        )
        let decoded = try JSONCoding.decoder.decode(SettingsTestSession.self, from: JSONCoding.encoder.encode(session))
        #expect(decoded == session)
    }
}
