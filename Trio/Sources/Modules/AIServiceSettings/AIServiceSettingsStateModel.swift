import SwiftUI

extension AIServiceSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Published var modelConfiguration = OpenRouterModelConfiguration()
        @Published var imageClassifierConfiguration = ImageClassifierConfiguration()
        @Published private(set) var decisionModels: [OpenRouterModel] = []
        @Published private(set) var decisionCatalogError: String?
        @Published private(set) var catalogModels: [OpenRouterModel] = []
        @Published private(set) var favoriteModelIDs: Set<String> = []
        @Published private(set) var catalogError: String?
        @Published private(set) var isLoadingCatalog = false

        private let catalogService = OpenRouterModelCatalogService.shared

        override func subscribe() {
            subscribeSetting(\.openRouterModelConfiguration, on: $modelConfiguration) { modelConfiguration = $0 }
            subscribeSetting(\.imageClassifierConfiguration, on: $imageClassifierConfiguration) {
                imageClassifierConfiguration = $0 }
            decisionModels = catalogService.cachedDecisionModels
            catalogModels = catalogService.cachedModels
            favoriteModelIDs = catalogService.favoriteModelIDs
        }

        @MainActor func refreshCatalog(forceRefresh: Bool = false) async {
            isLoadingCatalog = true
            defer { isLoadingCatalog = false }
            async let loadedDecisions = catalogService.loadDecisionModels(forceRefresh: forceRefresh)
            do {
                let models = try await catalogService.loadModels(forceRefresh: forceRefresh)
                if catalogModels != models {
                    catalogModels = models
                }
                catalogError = nil
            } catch {
                catalogError =
                    String(localized: "Could not refresh the OpenRouter catalog. Showing cached models when available.")
            }
            do {
                decisionModels = try await loadedDecisions
                decisionCatalogError = nil
            } catch {
                decisionCatalogError =
                    String(localized: "Could not refresh image decision models. Showing cached models when available.")
            }
        }

        func model(for modelID: String) -> OpenRouterModel? {
            if let option = OpenRouterFrontierOption(rawValue: modelID) {
                return OpenRouterFrontierModelResolver.model(for: option, in: catalogModels)
            }
            return catalogModels.first { $0.id == modelID }
        }

        func addModel(_ modelID: String) {
            var configuration = modelConfiguration
            guard configuration.add(modelID) else { return }
            modelConfiguration = configuration
        }

        func removeModels(at offsets: IndexSet) {
            var configuration = modelConfiguration
            for index in offsets.sorted(by: >) where index < configuration.selectedModelIDs.count {
                _ = configuration.remove(configuration.selectedModelIDs[index])
            }
            modelConfiguration = configuration
        }

        func moveModels(from offsets: IndexSet, to destination: Int) {
            var configuration = modelConfiguration
            configuration.move(fromOffsets: offsets, toOffset: destination)
            modelConfiguration = configuration
        }

        func setDefault(_ modelID: String) {
            var configuration = modelConfiguration
            guard configuration.setDefault(modelID) else { return }
            modelConfiguration = configuration
        }

        func toggleFavorite(_ modelID: String) {
            var favorites = favoriteModelIDs
            if favorites.contains(modelID) {
                favorites.remove(modelID)
            } else {
                favorites.insert(modelID)
            }
            favoriteModelIDs = favorites
            catalogService.favoriteModelIDs = favorites
        }
    }
}

extension AIServiceSettings.StateModel: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        modelConfiguration = settings.openRouterModelConfiguration
        imageClassifierConfiguration = settings.imageClassifierConfiguration
    }
}
