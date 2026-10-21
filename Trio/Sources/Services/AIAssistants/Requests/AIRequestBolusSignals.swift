import Combine
import Foundation

/// What Trio's APS manager says about a bolus the wearer asked for on the Treatments sheet.
struct AIRequestBolusSignals {
    /// `APSManager.bolusProgress`. It sends `0` when the pump accepts a bolus.
    let progress: CurrentValueSubject<Decimal?, Never>
    /// Sends for each `BolusFailureObserver.bolusDidFail()`: a bolus asked for by hand failed.
    let failures: AnyPublisher<Void, Never>
    /// The text of `APSManager.lastError`, if there is one.
    let lastErrorText: () -> String?
    /// The units the pump gives for an amount: `APSManager.roundBolus(amount:)`.
    let roundBolus: (Decimal) -> Decimal
    /// Stops the signals once they're no longer watched.
    var stop: () -> Void = {}

    /// Trio's own, or `nil` if its APS manager isn't there.
    @MainActor static func live() -> AIRequestBolusSignals? {
        let resolver = TrioApp.resolver
        guard let apsManager = resolver.resolve(APSManager.self),
              let broadcaster = resolver.resolve(Broadcaster.self)
        else { return nil }
        let relay = BolusFailureRelay()
        broadcaster.register(BolusFailureObserver.self, observer: relay)
        return AIRequestBolusSignals(
            progress: apsManager.bolusProgress,
            failures: relay.failures.eraseToAnyPublisher(),
            lastErrorText: { apsManager.lastError.value?.localizedDescription },
            roundBolus: { apsManager.roundBolus(amount: $0) },
            // The broadcaster holds its observers weakly, so the relay lives as long as this.
            stop: { broadcaster.unregister(BolusFailureObserver.self, observer: relay) }
        )
    }
}

/// Passes the broadcaster's `bolusDidFail()` on as a publisher.
private final class BolusFailureRelay: BolusFailureObserver {
    let failures = PassthroughSubject<Void, Never>()

    func bolusDidFail() {
        failures.send()
    }
}
