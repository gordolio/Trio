import Combine
import CoreData
import Foundation

/// A bolus in Trio's pump history: one the pump took, or external insulin logged by hand.
struct AIRequestPumpBolusEvent: Equatable {
    let timestamp: Date
    /// The units the pump took, or the external insulin logged.
    let amount: Decimal?
    /// The loop gave it: a super micro bolus or another automatic bolus.
    let isSMB: Bool
    let isExternal: Bool
}

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
    /// Sends each time Trio stores pump history: `PumpHistoryStorage.updatePublisher`.
    let historyUpdates: AnyPublisher<Void, Never>
    /// The boluses in the pump history timestamped at or after the date.
    let boluses: (Date) async -> [AIRequestPumpBolusEvent]
    /// Stops the signals once they're no longer watched.
    var stop: () -> Void = {}

    /// Trio's own, or `nil` if its APS manager isn't there.
    @MainActor static func live() -> AIRequestBolusSignals? {
        let resolver = TrioApp.resolver
        guard let apsManager = resolver.resolve(APSManager.self),
              let broadcaster = resolver.resolve(Broadcaster.self),
              let pumpHistory = resolver.resolve(PumpHistoryStorage.self)
        else { return nil }
        let relay = BolusFailureRelay()
        broadcaster.register(BolusFailureObserver.self, observer: relay)
        return AIRequestBolusSignals(
            progress: apsManager.bolusProgress,
            failures: relay.failures.eraseToAnyPublisher(),
            lastErrorText: { apsManager.lastError.value?.localizedDescription },
            roundBolus: { apsManager.roundBolus(amount: $0) },
            historyUpdates: pumpHistory.updatePublisher,
            boluses: { await storedBoluses(since: $0) },
            // The broadcaster holds its observers weakly, so the relay lives as long as this.
            stop: { broadcaster.unregister(BolusFailureObserver.self, observer: relay) }
        )
    }
}

extension AIRequestBolusSignals {
    /// Reads the boluses from Core Data, the way Trio stored them. It only reads.
    static func storedBoluses(since date: Date) async -> [AIRequestPumpBolusEvent] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "aiRequestBoluses"
        return await context.perform {
            let request = PumpEventStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "type == %@ AND timestamp >= %@ AND bolus != nil",
                PumpEventStored.EventType.bolus.rawValue,
                date as NSDate
            )
            request.relationshipKeyPathsForPrefetching = ["bolus"]
            let rows = (try? context.fetch(request)) ?? []
            return rows.compactMap { row in
                guard let timestamp = row.timestamp, let bolus = row.bolus else { return nil }
                return AIRequestPumpBolusEvent(
                    timestamp: timestamp,
                    amount: bolus.amount?.decimalValue,
                    isSMB: bolus.isSMB,
                    isExternal: bolus.isExternal
                )
            }
        }
    }
}

/// Passes the broadcaster's `bolusDidFail()` on as a publisher.
private final class BolusFailureRelay: BolusFailureObserver {
    let failures = PassthroughSubject<Void, Never>()

    func bolusDidFail() {
        failures.send()
    }
}
