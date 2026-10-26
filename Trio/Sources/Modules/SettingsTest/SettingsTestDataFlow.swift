enum SettingsTest {
    enum Config {}
}

protocol SettingsTestProvider {}
extension SettingsTest {
    final class Provider: BaseProvider, SettingsTestProvider {}
}
