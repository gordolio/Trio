protocol AIServiceSettingsProvider {}

extension AIServiceSettings {
    final class Provider: BaseProvider, AIServiceSettingsProvider {}
}
