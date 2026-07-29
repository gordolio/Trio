import Foundation
import LoopKit

// LoopKit adapter for `EventType`.
//
// Kept out of `PumpHistoryEvent.swift` so that the model itself stays Foundation-only and can be
// compiled by the algorithm package (see `AlgorithmPackage/Package.swift`). Consumed by
// `TidepoolManager`.
extension EventType {
    func mapEventTypeToPumpEventType() -> PumpEventType? {
        switch self {
        case .prime:
            return PumpEventType.prime
        case .pumpResume:
            return PumpEventType.resume
        case .rewind:
            return PumpEventType.rewind
        case .pumpSuspend:
            return PumpEventType.suspend
        case .nsBatteryChange,
             .pumpBattery:
            return PumpEventType.replaceComponent(componentType: .pump)
        case .nsInsulinChange:
            return PumpEventType.replaceComponent(componentType: .reservoir)
        case .nsSiteChange:
            return PumpEventType.replaceComponent(componentType: .infusionSet)
        case .pumpAlarm:
            return PumpEventType.alarm
        default:
            return nil
        }
    }
}
