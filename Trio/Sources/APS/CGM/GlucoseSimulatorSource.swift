/// Glucose source - Blood Glucose Simulator
///
/// Source publish fake data about glucose's level, creates ascending and descending trends
///
/// Enter point of Source is GlucoseSimulatorSource.fetch method. Method is called from FetchGlucoseManager module.
/// Not more often than a specified period (default - 300 seconds), it returns a Combine-publisher that publishes data on glucose values (global type BloodGlucose). If there is no up-to-date data (or the publication period has not passed yet), then a publisher of type Empty is returned, otherwise it returns a publisher of type Just.
///
/// Simulator composition
/// ===================
///
/// class GlucoseSimulatorSource - main class
/// protocol BloodGlucoseGenerator
///  - OscillatingGenerator: BloodGlucoseGenerator - Generates sinusoidal glucose values around a center point

import Combine
import CoreData
import Foundation
import LoopKit
import LoopKitUI

// MARK: - Glucose simulator

/// A class that simulates glucose values for testing purposes.
/// This class implements the GlucoseSource protocol and provides simulated glucose readings
/// using different generator strategies.
final class GlucoseSimulatorSource: GlucoseSource {
    var cgmManager: CGMManagerUI?
    var glucoseManager: FetchGlucoseManager?

    let cgmDisplayState = CurrentValueSubject<CgmDisplayState?, Never>(nil)
    let cgmProgressHighlight = CurrentValueSubject<DeviceLifecycleProgress?, Never>(nil)

    private enum Config {
        /// Minimum time period between data publications (in seconds)
        static let workInterval: TimeInterval = 300
        /// Default number of blood glucose items to generate at first run
        /// 288 = 1 day * 24 hours * 60 minutes * 60 seconds / workInterval
        static let defaultBGItems = 288
    }

    /// The last glucose value that was generated
    @Persisted(key: "GlucoseSimulatorLastGlucose") private var lastGlucose = 100

    /// The date of the last fetch operation
    @Persisted(key: "GlucoseSimulatorLastFetchDate") private var lastFetchDate: Date! = nil

    /// Initializes the glucose simulator source
    /// Sets up the initial fetch date if not already set
    init() {
        if lastFetchDate == nil {
            var lastDate = Date()
            for _ in 1 ... Config.defaultBGItems {
                lastDate = lastDate.addingTimeInterval(-Config.workInterval)
            }
            lastFetchDate = lastDate
        }
        publishSimulatedState()
    }

    /// Republishes synthetic lifecycle/highlight from `simulatedScenario`.
    func publishSimulatedState() {
        cgmProgressHighlight.value = cgmLifecycleProgress
        if let highlight = cgmStatusHighlight {
            cgmDisplayState.value = CgmDisplayState(
                localizedMessage: highlight.localizedMessage,
                imageName: highlight.imageName,
                status: CgmDisplayStatus.from(highlight.state)
            )
        } else {
            cgmDisplayState.value = nil
        }
    }

    /// Picker entry point — change scenario + propagate immediately. When
    /// flipping to a state where a real sensor wouldn't be delivering fresh
    /// readings, drop any GlucoseStored rows inside the home view's 12 min
    /// freshness window so the bobble switches to its compact stale view
    /// right away instead of waiting for organic aging.
    func applySimulatedScenario(_ scenario: SimulatedSensorScenario) {
        simulatedScenario = scenario
        if !scenario.deliversFreshGlucose {
            clearRecentSimulatorReadings()
        }
        publishSimulatedState()
    }

    /// Deletes GlucoseStored rows newer than the home view's 12 min
    /// freshness window. Dev-only — only invoked from the simulator's
    /// scenario picker, which is itself gated to simulator mode.
    private func clearRecentSimulatorReadings() {
        let context = CoreDataStack.shared.newTaskContext()
        let cutoff = Date().addingTimeInterval(-12 * 60)
        context.perform {
            let request = GlucoseStored.fetchRequest()
            request.predicate = NSPredicate(format: "date > %@", cutoff as NSDate)
            do {
                let recent = try context.fetch(request)
                for row in recent {
                    context.delete(row)
                }
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                print("GlucoseSimulatorSource: clearRecentSimulatorReadings failed: \(error)")
            }
        }
    }

    /// The glucose generator used to create simulated values
    /// Uses OscillatingGenerator to create a sinusoidal pattern around 120 mg/dL
    private lazy var generator: BloodGlucoseGenerator = {
        OscillatingGenerator()
    }()

    /// Determines if new glucose values can be generated based on the time elapsed since the last fetch
    private var canGenerateNewValues: Bool {
        guard let lastDate = lastFetchDate else { return true }
        if Calendar.current.dateComponents([.second], from: lastDate, to: Date()).second! >= Int(Config.workInterval) {
            return true
        } else {
            return false
        }
    }

    /// Fetches new glucose values if enough time has passed since the last fetch
    /// - Parameter timer: Optional dispatch timer (not used in this implementation)
    /// - Returns: A publisher that emits an array of BloodGlucose objects
    func fetch(_: DispatchTimer?) -> AnyPublisher<[BloodGlucose], Never> {
        guard canGenerateNewValues else {
            return Just([]).eraseToAnyPublisher()
        }
        // Match real CGM behavior: scenarios where a physical sensor wouldn't
        // be delivering readings (warmup, calibration, expired, failed) also
        // stop the simulator from emitting fresh values. Existing readings
        // then age out of the 12 min freshness window, the bobble flips to
        // its compact symbol view, and the highlight's imageName surfaces.
        guard simulatedScenario.deliversFreshGlucose else {
            return Just([]).eraseToAnyPublisher()
        }

        let glucoses = generator.getBloodGlucoses(
            startDate: lastFetchDate,
            finishDate: Date(),
            withInterval: Config.workInterval
        )

        if let lastItem = glucoses.last {
            lastGlucose = lastItem.glucose!
            lastFetchDate = Date()
        }

        return Just(glucoses).eraseToAnyPublisher()
    }

    /// Fetches new glucose values if needed
    /// - Returns: A publisher that emits an array of BloodGlucose objects
    func fetchIfNeeded() -> AnyPublisher<[BloodGlucose], Never> {
        fetch(nil)
    }

    // MARK: - Simulated sensor lifecycle / status (dev-only)

    //
    // The simulator doesn't own a real `CGMManagerUI`, so `cgmStatusHighlight`
    // and `cgmLifecycleProgress` would be nil on the home screen. To make the
    // outer arc + tag indicator actually exercisable without Libre/Dexcom
    // hardware, the simulator exposes synthetic values driven by
    // `simulatedScenario`. Flip the persisted enum at runtime (debug menu or
    // by editing the default below) and the home view picks up the change on
    // its next 5-second refresh tick.

    /// Which pre-canned sensor state the simulator should advertise. Plain
    /// `UserDefaults` string access (not `@Persisted`) so the CGM-settings
    /// picker — which writes via `UserDefaults.standard.set(_:forKey:)` — and
    /// the read here use the same encoding. `@Persisted` stores values as
    /// JSON-wrapped `Data`, which would silently break the picker round-trip.
    static let simulatedScenarioKey = "GlucoseSimulator.simulatedScenario"

    var simulatedScenario: SimulatedSensorScenario {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.simulatedScenarioKey)
            return raw.flatMap(SimulatedSensorScenario.init(rawValue:)) ?? .runningNormally
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.simulatedScenarioKey)
        }
    }

    /// Synthetic expiration date that mirrors what a real CGM would expose.
    /// Picked so the remaining-time label matches the scenario's
    /// `percentComplete` against a 10-day total (Dexcom-like).
    var simulatedSensorExpiresAt: Date? {
        guard let progress = cgmLifecycleProgress else { return nil }
        let totalLifetime: TimeInterval = 10 * 24 * 60 * 60
        let remaining = (1.0 - progress.percentComplete) * totalLifetime
        return Date().addingTimeInterval(remaining)
    }

    /// Synthetic outer-arc data — nil for scenarios where lifetime is moot
    /// (warmup, hardware fault). Matches the production `DeviceLifecycleProgress`
    /// shape so the home state model can treat both sources identically.
    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        switch simulatedScenario {
        case .runningNormally:
            return SimulatedLifecycleProgress(percentComplete: 0.45, progressState: .normalCGM)
        case .expiringSoon:
            return SimulatedLifecycleProgress(percentComplete: 0.94, progressState: .warning)
        case .warmup:
            return nil
        case .calibrationRequired:
            return SimulatedLifecycleProgress(percentComplete: 0.30, progressState: .normalCGM)
        case .expired:
            return SimulatedLifecycleProgress(percentComplete: 1.0, progressState: .critical)
        case .sensorFailed:
            return nil
        }
    }

    /// Synthetic status highlight. nil for `.runningNormally` and
    /// `.expiringSoon` (those run off lifecycle only).
    var cgmStatusHighlight: DeviceStatusHighlight? {
        switch simulatedScenario {
        case .expiringSoon,
             .runningNormally:
            return nil
        case .warmup:
            return SimulatedStatusHighlight(
                localizedMessage: "Sensor warming up",
                imageName: "hourglass",
                state: .warning
            )
        case .calibrationRequired:
            return SimulatedStatusHighlight(
                localizedMessage: "Calibrate",
                imageName: "drop.fill",
                state: .warning
            )
        case .expired:
            return SimulatedStatusHighlight(
                localizedMessage: "Sensor expired",
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        case .sensorFailed:
            return SimulatedStatusHighlight(
                localizedMessage: "Replace Sensor",
                imageName: "exclamationmark.triangle.fill",
                state: .critical
            )
        }
    }
}

/// Pre-canned sensor scenarios surfaced by `GlucoseSimulatorSource`. One per
/// home-screen state so flipping this drives the indicator
/// through every visual state.
enum SimulatedSensorScenario: String, CaseIterable, Identifiable {
    case runningNormally
    case expiringSoon
    case warmup
    case calibrationRequired
    case expired
    case sensorFailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .runningNormally: return "Running normally"
        case .expiringSoon: return "Expiring soon"
        case .warmup: return "Warmup"
        case .calibrationRequired: return "Calibration required"
        case .expired: return "Expired"
        case .sensorFailed: return "Sensor failed"
        }
    }

    /// Whether a real CGM would still be delivering fresh glucose readings
    /// while in this state. Drives the simulator's `fetch()` gate so non-
    /// active scenarios stop emitting and the home view sees stale data
    /// the same way it would from a real sensor.
    var deliversFreshGlucose: Bool {
        switch self {
        case .expiringSoon,
             .runningNormally:
            return true
        case .calibrationRequired,
             .expired,
             .sensorFailed,
             .warmup:
            return false
        }
    }

    /// Short blurb shown under the picker so dev users know what each
    /// scenario renders on the home screen.
    var devNotes: String {
        switch self {
        case .runningNormally:
            return "Teal outer ring at ~45%, tag shows time remaining."
        case .expiringSoon:
            return "Amber outer ring at ~94%, tag shows time remaining with \"left\" suffix."
        case .warmup:
            return "Arc hidden, pulsing amber tag, glucose shown as \"– –\"."
        case .calibrationRequired:
            return "Arc visible, amber tag with \"Calibrate\" message, glucose still shown."
        case .expired:
            return "Red full ring, red tag \"sensor expired\", glucose shown as \"– –\"."
        case .sensorFailed:
            return "Arc hidden, pulsing red tag, glucose shown as \"– –\"."
        }
    }
}

private struct SimulatedLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}

private struct SimulatedStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

// MARK: - Glucose generator

/// Protocol defining the interface for glucose generators
/// Implementations of this protocol provide different strategies for generating glucose values
protocol BloodGlucoseGenerator {
    /// Generates blood glucose values between the specified dates at the given interval
    /// - Parameters:
    ///   - startDate: The start date for generating values
    ///   - finishDate: The end date for generating values
    ///   - interval: The time interval between generated values
    /// - Returns: An array of BloodGlucose objects
    func getBloodGlucoses(startDate: Date, finishDate: Date, withInterval: TimeInterval) -> [BloodGlucose]
}

/// A glucose generator that creates a sinusoidal pattern around a center value
/// This generator simulates a realistic oscillating glucose pattern with configurable parameters
class OscillatingGenerator: BloodGlucoseGenerator {
    /// Default values for simulator parameters
    enum Defaults {
        static let centerValue: Double = 120.0
        static let amplitude: Double = 45.0
        static let period: Double = 10800.0 // 3 hours in seconds
        static let noiseAmplitude: Double = 5.0
        static let produceStaleValues: Bool = false
        /// Default target glucose delta at 90 minutes for tablet simulation (mg/dL)
        static let tabletTargetDelta: Double = 25.0
    }

    /// UserDefaults keys for storing simulator parameters
    private enum UserDefaultsKeys {
        static let centerValue = "GlucoseSimulator_CenterValue"
        static let amplitude = "GlucoseSimulator_Amplitude"
        static let period = "GlucoseSimulator_Period"
        static let noiseAmplitude = "GlucoseSimulator_NoiseAmplitude"
        static let produceStaleValues = "GlucoseSimulator_ProduceStaleValues"
        /// TimeIntervalSince1970 when the simulated tablet was taken (0 = no active tablet)
        static let tabletTakenDate = "GlucoseSimulator_TabletTakenDate"
        /// Target glucose delta in mg/dL at 90 minutes after taking the tablet
        static let tabletTargetDelta = "GlucoseSimulator_TabletTargetDelta"
    }

    /// Amplitude of the oscillation (±45 mg/dL to create range from ~80 to ~170).
    /// Note: 0 is a valid value (flat line), so the getter uses `object(forKey:)` nil check.
    private var amplitude: Double {
        get {
            UserDefaults.standard.object(forKey: UserDefaultsKeys.amplitude) != nil
                ? UserDefaults.standard.double(forKey: UserDefaultsKeys.amplitude)
                : Defaults.amplitude
        }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.amplitude) }
    }

    /// Period of the oscillation in seconds (3 hours = 10800 seconds)
    private var period: Double {
        get {
            UserDefaults.standard.object(forKey: UserDefaultsKeys.period) != nil
                ? UserDefaults.standard.double(forKey: UserDefaultsKeys.period)
                : Defaults.period
        }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.period) }
    }

    /// Center value of the oscillation (target glucose level)
    private var centerValue: Double {
        get {
            UserDefaults.standard.object(forKey: UserDefaultsKeys.centerValue) != nil
                ? UserDefaults.standard.double(forKey: UserDefaultsKeys.centerValue)
                : Defaults.centerValue
        }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.centerValue) }
    }

    /// Amplitude of random noise to add to the values (±5 mg/dL).
    /// Note: 0 is a valid value (no noise), so the getter uses `object(forKey:)` nil check.
    private var noiseAmplitude: Double {
        get {
            UserDefaults.standard.object(forKey: UserDefaultsKeys.noiseAmplitude) != nil
                ? UserDefaults.standard.double(forKey: UserDefaultsKeys.noiseAmplitude)
                : Defaults.noiseAmplitude
        }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.noiseAmplitude) }
    }

    /// Whether to produce stale (unchanging) glucose values
    var produceStaleValues: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.produceStaleValues) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.produceStaleValues) }
    }

    // MARK: - Glucose Tablet Simulation

    /// Date when the simulated glucose tablet was taken (nil = no active tablet).
    /// Stored as TimeIntervalSince1970 in UserDefaults; 0 means no tablet.
    var tabletTakenDate: Date? {
        get {
            let ti = UserDefaults.standard.double(forKey: UserDefaultsKeys.tabletTakenDate)
            return ti > 0 ? Date(timeIntervalSince1970: ti) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: UserDefaultsKeys.tabletTakenDate)
            } else {
                UserDefaults.standard.set(0.0, forKey: UserDefaultsKeys.tabletTakenDate)
            }
        }
    }

    /// Target glucose delta in mg/dL at 90 minutes after taking the simulated tablet.
    ///
    /// This controls the net glucose change the tablet produces at the end of the
    /// calibration observation period:
    /// - **Positive** (e.g., +25): glucose rises → calibration suggests lowering CR (ratio too weak)
    /// - **Negative** (e.g., -25): glucose drops → calibration suggests raising CR (ratio too strong)
    /// - **Zero**: glucose unchanged → calibration confirms CR is correct
    ///
    /// Note: 0.0 is a valid value (tests "ratio correct"), so the getter checks whether
    /// the key exists rather than checking for zero.
    var tabletTargetDelta: Double {
        get {
            let key = UserDefaultsKeys.tabletTargetDelta
            if UserDefaults.standard.object(forKey: key) == nil {
                return Defaults.tabletTargetDelta
            }
            return UserDefaults.standard.double(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.tabletTargetDelta) }
    }

    /// Whether a tablet simulation is currently active (within the 120-minute effect window).
    var isTabletActive: Bool {
        guard let takenDate = tabletTakenDate else { return false }
        return Date().timeIntervalSince(takenDate) < 7200 // 120 minutes
    }

    /// Simulate taking a glucose tablet at the current time.
    /// The tablet effect will be added to the glucose generation for the next 120 minutes.
    func simulateTablet() {
        tabletTakenDate = Date()
    }

    /// Start date for the simulation
    private let startup = Date()

    /// Last generated glucose value for stale mode
    private var lastGeneratedGlucose: Int?

    /// Provides information string to describe the simulator as glucose source
    func sourceInfo() -> [String: Any]? {
        [GlucoseSourceKey.description.rawValue: "Glucose simulator"]
    }

    /// Reset all parameters to default values
    func resetToDefaults() {
        centerValue = Defaults.centerValue
        amplitude = Defaults.amplitude
        period = Defaults.period
        noiseAmplitude = Defaults.noiseAmplitude
        produceStaleValues = Defaults.produceStaleValues
        lastGeneratedGlucose = nil
        tabletTakenDate = nil
        tabletTargetDelta = Defaults.tabletTargetDelta
    }

    /// Generates blood glucose values between the specified dates at the given interval
    /// - Parameters:
    ///   - startDate: The start date for generating values
    ///   - finishDate: The end date for generating values
    ///   - interval: The time interval between generated values
    /// - Returns: An array of BloodGlucose objects with sinusoidal pattern
    func getBloodGlucoses(startDate: Date, finishDate: Date, withInterval interval: TimeInterval) -> [BloodGlucose] {
        var result = [BloodGlucose]()
        var currentDate = startDate

        while currentDate <= finishDate {
            let glucose: Int
            let direction: BloodGlucose.Direction

            if produceStaleValues, lastGeneratedGlucose != nil {
                // In stale mode, use the last generated glucose value
                glucose = lastGeneratedGlucose!
                direction = .flat
            } else {
                // Generate a new glucose value
                glucose = generate(date: currentDate)
                direction = calculateDirection(at: currentDate)
                lastGeneratedGlucose = glucose
            }

            // Create BloodGlucose with the correct constructor
            let bloodGlucose = BloodGlucose(
                id: UUID().uuidString,
                sgv: glucose,
                direction: direction,
                date: Decimal(Int(currentDate.timeIntervalSince1970) * 1000),
                dateString: currentDate,
                unfiltered: Decimal(glucose),
                filtered: nil,
                noise: nil,
                glucose: glucose,
                type: nil,
                activationDate: startup,
                sessionStartDate: startup,
                transmitterID: "SIMULATOR"
            )

            result.append(bloodGlucose)
            currentDate = currentDate.addingTimeInterval(interval)
        }

        return result
    }

    /// Returns the deterministic glucose value at a given date (no random noise).
    /// Useful for UI previews showing "Current BG" and "Next BG" without jitter.
    /// - Parameter date: The date for which to preview the glucose value
    /// - Returns: An integer representing the glucose value in mg/dL
    func previewGlucose(at date: Date) -> Int {
        let timeSeconds = date.timeIntervalSince1970
        let sinValue = sin(2.0 * .pi * timeSeconds / period)
        let tablet = tabletEffect(at: date)
        return Int(centerValue + amplitude * sinValue + tablet)
    }

    /// Generates a glucose value for the specified date using a sinusoidal function,
    /// with an optional glucose tablet effect overlaid on top.
    /// - Parameter date: The date for which to generate the glucose value
    /// - Returns: An integer representing the glucose value in mg/dL
    private func generate(date: Date) -> Int {
        // Time in seconds since 1970
        let timeSeconds = date.timeIntervalSince1970

        // Calculate sine value
        let sinValue = sin(2.0 * .pi * timeSeconds / period)

        // Random noise
        let noise = Double.random(in: -noiseAmplitude ... noiseAmplitude)

        // Glucose tablet effect (additive; 0 if no tablet active)
        let tablet = tabletEffect(at: date)

        // Auto-cleanup expired tablet (120+ minutes after taken)
        if let takenDate = tabletTakenDate, date.timeIntervalSince(takenDate) >= 7200 {
            tabletTakenDate = nil
        }

        // Calculate glucose value: center + amplitude * sine + noise + tablet effect
        let glucoseValue = centerValue + amplitude * sinValue + noise + tablet

        // Return as integer
        return Int(glucoseValue)
    }

    // MARK: - Tablet Effect Math

    /// Calculates the glucose effect of a simulated tablet at the given date.
    ///
    /// Uses a piecewise model with three phases:
    ///
    /// 1. **Rise (0 → 30 min):** Quadratic rise to a ~35 mg/dL peak.
    ///    Starts strong, decelerates into peak — mimicking fast glucose tablet absorption.
    ///
    /// 2. **Decline (30 → 90 min):** Linear decline from peak toward `targetDelta`.
    ///    Reaches exactly `targetDelta` at the 90-minute observation mark.
    ///
    /// 3. **Tail (90 → 120 min):** Linear fade from `targetDelta` to 0.
    ///
    /// The net effect at 90 minutes equals exactly `targetDelta`:
    /// - **targetDelta = 0 ("Correct")**: rises ~35, declines linearly back to 0
    /// - **targetDelta > 0 ("Weak")**: rises ~35, gentle decline to +delta
    /// - **targetDelta < 0 ("Strong")**: rises ~35, steeper decline through 0 to -delta
    ///
    /// At t ≥ 120 min the effect is zero and the tablet record auto-cleaned.
    ///
    /// - Parameter date: The date for which to calculate the tablet effect
    /// - Returns: The glucose offset in mg/dL to add to the base sine wave
    func tabletEffect(at date: Date) -> Double {
        guard let takenDate = tabletTakenDate else { return 0 }

        let t = date.timeIntervalSince(takenDate)

        // Before tablet was taken or after the 120-minute cutoff
        guard t >= 0, t < 7200 else { return 0 }

        let tMin = t / 60.0
        let peakMg: Double = 35.0
        let riseDuration: Double = 30.0 // minutes to reach peak
        let observationEnd: Double = 90.0
        let totalDuration: Double = 120.0

        if tMin <= riseDuration {
            // Phase 1: Quadratic rise — fast initial rise, decelerating into peak
            let frac = tMin / riseDuration
            return peakMg * (2.0 * frac - frac * frac)
        } else if tMin <= observationEnd {
            // Phase 2: Linear decline from peak toward targetDelta at 90 min
            let elapsed = tMin - riseDuration
            let duration = observationEnd - riseDuration
            return peakMg - (peakMg - tabletTargetDelta) * (elapsed / duration)
        } else {
            // Phase 3: Linear fade from targetDelta to 0 at 120 min
            let elapsed = tMin - observationEnd
            let duration = totalDuration - observationEnd
            return tabletTargetDelta * (1.0 - elapsed / duration)
        }
    }

    /// Calculates the direction (trend) of glucose change at the specified date.
    /// Combines the sine wave derivative with the tablet effect rate of change.
    /// - Parameter date: The date for which to calculate the direction
    /// - Returns: A BloodGlucose.Direction value indicating the trend
    private func calculateDirection(at date: Date) -> BloodGlucose.Direction {
        // Time in seconds since 1970
        let timeSeconds = date.timeIntervalSince1970

        // Sine wave derivative (cosine)
        let cosValue = cos(2.0 * .pi * timeSeconds / period)
        let sineSlope = -amplitude * 2.0 * .pi / period * cosValue

        // Tablet effect derivative (numerical finite difference)
        var tabletSlope: Double = 0
        if tabletTakenDate != nil {
            let dt: Double = 30 // 30-second finite difference
            let tabletNow = tabletEffect(at: date)
            let tabletNext = tabletEffect(at: date.addingTimeInterval(dt))
            tabletSlope = (tabletNext - tabletNow) / dt
        }

        // Combined slope from sine wave + tablet effect
        let slope = sineSlope + tabletSlope

        // Determine direction based on combined slope
        if abs(slope) < 0.2 {
            return .flat
        } else if slope > 0 {
            if slope > 1.0 {
                return .singleUp
            } else {
                return .fortyFiveUp
            }
        } else {
            if slope < -1.0 {
                return .singleDown
            } else {
                return .fortyFiveDown
            }
        }
    }
}
