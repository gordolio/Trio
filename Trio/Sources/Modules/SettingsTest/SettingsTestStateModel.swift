import Combine
import Observation
import SwiftUI

extension SettingsTest {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var testService: SettingsTestService!

        /// The test that is running right now, if any.
        var activeSession: SettingsTestSession?

        /// Most recent finished test per kind.
        var lastRecords: [SettingsTestKind: SettingsTestRecord] = [:]

        var glucoseUnits: GlucoseUnits {
            let manager: SettingsManager? = settingsManager
            return manager?.settings.units ?? .mgdL
        }

        override func subscribe() {
            activeSession = testService.activeSession
            refreshHistory()

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
        }

        /// Where tapping a test goes.
        func screen(for kind: SettingsTestKind) -> Screen? {
            switch kind {
            case .carbRatio: return .carbRatioCalibration
            case .basal: return .basalTest
            case .isf: return nil
            }
        }
    }
}
