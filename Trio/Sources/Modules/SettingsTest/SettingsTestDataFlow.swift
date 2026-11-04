enum SettingsTest {
    enum Config {}
}

protocol SettingsTestProvider {}
extension SettingsTest {
    final class Provider: BaseProvider, SettingsTestProvider {
        /// The basal schedule, empty when there is none saved.
        func basalEntries() -> [SettingsTestScheduleEntry] {
            SettingsTestSchedule.basalEntries(from: storage)
        }

        /// The insulin sensitivity schedule in mg/dL per unit, empty when there is none saved.
        func isfEntries() -> [SettingsTestScheduleEntry] {
            SettingsTestSchedule.isfEntries(from: storage)
        }
    }
}
