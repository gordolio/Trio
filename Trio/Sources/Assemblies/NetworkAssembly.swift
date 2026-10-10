import Foundation
import Swinject

final class NetworkAssembly: Assembly {
    func assemble(container: Container) {
        container.register(ReachabilityManager.self) { _ in
            NetworkReachabilityManager()!
        }

        container.register(NightscoutManager.self) { r in BaseNightscoutManager(resolver: r) }
        NightscoutBackfill.register(in: container)
        container.register(TidepoolManager.self) { r in BaseTidepoolManager(resolver: r) }
    }
}
