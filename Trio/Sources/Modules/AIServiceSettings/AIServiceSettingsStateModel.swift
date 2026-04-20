import SwiftUI

extension AIServiceSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Published var aiProvider: AIProviderType = .openai

        override func subscribe() {
            subscribeSetting(\.aiProvider, on: $aiProvider) { aiProvider = $0 }
        }
    }
}

extension AIServiceSettings.StateModel: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        aiProvider = settings.aiProvider
    }
}
