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

        /// What the newest basal test says about starting a sensitivity test, or nil until it has been read. A warning
        /// only: it never locks the row.
        var basalGate: SettingsTestSchedule.BasalGate?

        /// Whether the old carb ratio wizard left a test under way. Its row then offers to end it; it never opens the
        /// wizard, which is being rebuilt.
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

            isfPeriods = SettingsTestSchedule.periods(
                for: .isf,
                current: provider.isfEntries(),
                history: testService.history(for: .isf)
            )
        }

        /// The warning under the sensitivity row, or nil when the newest basal test is steady, and while a test runs,
        /// when the row says that instead.
        var isfGateNote: String? {
            guard activeSession == nil, let basalGate else { return nil }
            return SettingsTestKind.isfGateNote(for: basalGate)
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

        /// Only one test runs at a time, so while one does, the others can't start.
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

        /// Where tapping a test goes, or nil while it can't be opened. The old carb ratio wizard is never opened, even
        /// with a test of its own under way, so its bolus and ratio change can't be reached.
        func screen(for kind: SettingsTestKind) -> Screen? {
            guard kind.availability == .available, !isLocked(kind) else { return nil }
            switch kind {
            case .basal: return .basalTest
            case .isf: return .isfTest
            case .carbRatio: return nil
            }
        }
    }
}
