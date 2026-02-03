import AppIntents
import Foundation
import Swinject

@available(iOS 16.0, *) struct OpenTreatmentIntent: AppIntent {
    static var title = LocalizedStringResource("Open Treatment")
    static var description = IntentDescription(.init("Opens the Treatment panel in Trio"))
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult {
        let resolver = TrioApp.resolver
        let router = resolver.resolve(Router.self)!
        router.mainModalScreen.send(.treatmentView)
        return .result()
    }
}
