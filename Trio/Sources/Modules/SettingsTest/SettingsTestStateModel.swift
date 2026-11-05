import Combine
import Observation
import SwiftUI

extension SettingsTest {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!
        @ObservationIgnored @Injected() var calibrationService: CalibrationModeService!

        /// The test that is running right now, if any.
        var activeSession: SettingsTestSession?

        /// Most recent finished test per kind.
        var lastRecords: [SettingsTestKind: SettingsTestRecord] = [:]

        /// The basal schedule's entries, each with what its latest test said.
        var basalPeriods: [SettingsTestPeriod] = []

        /// The insulin sensitivity schedule's entries, each with what its latest test said.
        var isfPeriods: [SettingsTestPeriod] = []

        /// The carb ratio schedule's entries, each with what its latest test said.
        var carbRatioPeriods: [SettingsTestPeriod] = []

        /// What the newest basal test says about starting a sensitivity test, or nil until it has been read. A warning
        /// only: it never locks the row.
        var basalGate: SettingsTestSchedule.BasalGate?

        /// What the newest ISF test says about starting a carb ratio test, or nil until it has been read. A warning only:
        /// it never locks the row (round 7 Q4).
        var isfGate: SettingsTestSchedule.ISFGate?

        /// Whether the old carb ratio wizard left a test under way. Its row then offers to end it; it never opens the
        /// wizard, nor the carb ratio test while it is there.
        var carbRatioInProgress = false

        /// Why the last try to end that test didn't, or nil.
        var carbRatioEndError: String?

        var glucoseUnits: GlucoseUnits {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.units ?? .mgdL
        }

        override func subscribe() {
            activeSession = testService.activeSession
            refreshHistory()
            refreshCarbRatio()

            testService.sessionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in
                    self?.activeSession = session
                    self?.refreshHistory()
                }
                .store(in: &lifetime)

            // The session ends before the runner archives, so its end alone would leave the rows a test behind.
            Self.testFinishes(
                isf: testService.isfRunner?.statePublisher,
                basal: testService.basalRunner?.statePublisher,
                carbRatio: testService.carbRatioRunner?.statePublisher
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshHistory() }
            .store(in: &lifetime)
        }

        /// Each time a runner's test reaches `.finished`: the runner archives a verdict in the same step as that save, after
        /// it ended the session, so the session's end alone comes before the history has it. Not for the test each runner
        /// holds as this is subscribed, which `subscribe` reads already.
        static func testFinishes(
            isf: AnyPublisher<ISFTestRunnerState, Never>?,
            basal: AnyPublisher<BasalTestState?, Never>?,
            carbRatio: AnyPublisher<CarbRatioTestRunnerState, Never>? = nil
        ) -> AnyPublisher<Void, Never> {
            /// The ID of the test a runner holds once it has finished, each new one once.
            func finished(_ ids: AnyPublisher<UUID?, Never>) -> AnyPublisher<Void, Never> {
                ids.removeDuplicates().dropFirst().compactMap { $0.map { _ in () } }.eraseToAnyPublisher()
            }
            let isfFinishes = isf.map { publisher in
                finished(publisher.map { $0.test.flatMap { $0.phase == .finished ? $0.id : nil } }.eraseToAnyPublisher())
            }
            let basalFinishes = basal.map { publisher in
                finished(publisher.map { $0.flatMap { $0.phase == .finished ? $0.id : nil } }.eraseToAnyPublisher())
            }
            let carbRatioFinishes = carbRatio.map { publisher in
                finished(publisher.map { $0.test.flatMap { $0.phase == .finished ? $0.id : nil } }.eraseToAnyPublisher())
            }
            return Publishers.MergeMany([isfFinishes, basalFinishes, carbRatioFinishes].compactMap { $0 })
                .eraseToAnyPublisher()
        }

        func refreshHistory() {
            var latest: [SettingsTestKind: SettingsTestRecord] = [:]
            for kind in SettingsTestKind.allCases {
                if let record = testService.history(for: kind).first {
                    latest[kind] = record
                }
            }
            lastRecords = latest

            let basalEntries = provider.basalEntries()
            let basalHistory = testService.history(for: .basal)
            basalPeriods = SettingsTestSchedule.periods(for: .basal, current: basalEntries, history: basalHistory)
            basalGate = SettingsTestSchedule.basalGate(history: basalHistory, current: basalEntries)

            let isfEntries = provider.isfEntries()
            let isfHistory = testService.history(for: .isf)
            isfPeriods = SettingsTestSchedule.periods(for: .isf, current: isfEntries, history: isfHistory)
            isfGate = SettingsTestSchedule.isfGate(history: isfHistory, current: isfEntries)

            carbRatioPeriods = SettingsTestSchedule.periods(
                for: .carbRatio,
                current: provider.carbRatioEntries(),
                history: testService.history(for: .carbRatio)
            )
        }

        /// The warning under the sensitivity row, or nil when the newest basal test is steady, and while a test runs,
        /// when the row says that instead.
        var isfGateNote: String? {
            guard activeSession == nil, let basalGate else { return nil }
            return SettingsTestKind.isfGateNote(for: basalGate)
        }

        /// The warning under the carb ratio row, or nil when the newest ISF test looked accurate on an unchanged schedule,
        /// and while a test runs, when the row says that instead.
        var carbRatioGateNote: String? {
            guard activeSession == nil, let isfGate else { return nil }
            return SettingsTestKind.carbRatioGateNote(for: isfGate)
        }

        /// A carb ratio in grams per unit as the hub lists it, e.g. "10 g/U". The unit never breaks across lines.
        func formatCarbRatio(_ grams: Decimal) -> String {
            SettingsTestFormat.keepTogether(grams.formatted(.number.precision(.fractionLength(0 ... 1))), unit: "g/U")
        }

        /// A sensitivity in mg/dL per unit, in the user's units.
        func formatISF(_ mgdl: Decimal) -> String {
            SettingsTestKind.isfText(mgdl, units: glucoseUnits)
        }

        /// The carb ratio wizard recovers its saved test only when its own screen opens, so before that the saved file
        /// is what says one is under way.
        func refreshCarbRatio() {
            let test = calibrationService.currentTest ?? calibrationService.loadExistingTest()
            carbRatioInProgress = SettingsTestKind.carbRatioTestInProgress(test?.phase)
        }

        /// Only one test runs at a time, so while one does, the others can't start. Their screens still open, so their
        /// steps can be read; each one's Check is what blocks the start.
        func isLocked(_ kind: SettingsTestKind) -> Bool {
            guard let running = activeSession?.kind else { return false }
            return running != kind
        }

        /// Ends the old carb ratio wizard's test without opening the wizard, with the calls its own Cancel makes: its
        /// Calibration Mode override goes off, its notifications are withdrawn, Nightscout gets the same note, and the
        /// saved test is cleared. If the override can't be turned off the test is kept, so the row still offers this.
        func endCarbRatioTest() async {
            do {
                try await calibrationService.deactivateCalibrationOverride()
            } catch {
                warning(.settings, "SettingsTest: couldn't turn off the carb ratio test's override", error: error)
                await MainActor.run {
                    carbRatioEndError = String(
                        localized: "Trio couldn't turn off the test's Calibration Mode override. Try again."
                    )
                }
                return
            }
            calibrationService.cancelScheduledNotifications()
            calibrationService.postNightscoutNote("Carb Ratio Calibration: Aborted (user cancelled)")
            calibrationService.clearTest()
            await MainActor.run {
                carbRatioEndError = nil
                refreshCarbRatio()
            }
        }

        /// Where tapping a test goes, or nil while it can't be opened. A test opens while another runs, so its steps and
        /// checks can be read; its Check screen says another test is running and keeps Begin off. The old carb ratio
        /// wizard is never opened, even with a test of its own under way, so its bolus and ratio change can't be reached;
        /// while that test is under way the carb ratio row offers to end it instead of opening the carb ratio test.
        func screen(for kind: SettingsTestKind) -> Screen? {
            guard kind.availability == .available else { return nil }
            if kind == .carbRatio, carbRatioInProgress { return nil }
            return kind.testScreen
        }
    }
}
