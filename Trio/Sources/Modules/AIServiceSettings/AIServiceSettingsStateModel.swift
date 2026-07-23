import SwiftUI

extension AIServiceSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Published var aiProvider: AIProviderType = .openai
        @Published var sendToAllAIProvidersSimultaneously: Bool = false

        override func subscribe() {
            subscribeSetting(\.aiProvider, on: $aiProvider) { aiProvider = $0 }
            subscribeSetting(\.sendToAllAIProvidersSimultaneously, on: $sendToAllAIProvidersSimultaneously) {
                sendToAllAIProvidersSimultaneously = $0
            }
        }
    }
}

extension AIServiceSettings.StateModel: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        aiProvider = settings.aiProvider
        sendToAllAIProvidersSimultaneously = settings.sendToAllAIProvidersSimultaneously
    }
}
