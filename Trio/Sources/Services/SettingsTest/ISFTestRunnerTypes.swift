import Combine
import Foundation

// What the ISF test's runner and its screen share: the reads, the state the runner publishes, and the actions the
// screen passes on (`ISFTestRunner`).

/// What the ISF test reads, by its screen and by its runner with the screen closed. `ISFTest.Provider` conforms, so each
/// read has one implementation.
protocol ISFTestReads: AnyObject {
    func isfEntries() -> [SettingsTestScheduleEntry]
    func targetEntries() -> [SettingsTestScheduleEntry]
    func isf(at date: Date) -> Decimal?
    func target(at date: Date) -> Decimal?
    func carbRatio(at date: Date) -> Decimal?
    func currentIOB() -> Decimal?
    func currentCOB() async throws -> Decimal?
    func pumpDelivery() -> ISFTestPumpDelivery?
    func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading]
    func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading]
    func fetchNewestDirection() async throws -> BloodGlucose.Direction?
    func fetchDeterminations(from start: Date, to end: Date) async throws -> [ISFTestDetermination]
    func fetchBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus]
    func fetchBolusRecords(from start: Date, to end: Date) async throws -> [ISFTestBolusRecord]
    func fetchSMBs(since start: Date, until end: Date) async throws -> [BasalTestSMB]
    func fetchTempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal]
    /// When Trio's determinations in the window asked for a zero temp with time on it (`SettingsTestEvents`).
    func zeroTempDeterminations(from start: Date, to end: Date) async throws -> [Date]
    func fetchArrowReading(atOrBefore date: Date) async throws -> ISFTestArrowReading?
    func fetchSuspendReading(startedAt: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading
    func fetchPumpInterruptions(from start: Date, to end: Date) async throws -> [Date]
    func fetchCarbEntries(from start: Date, to end: Date) async throws -> [SettingsTestCarbEntry]
    /// Whether an override or a temp target is running, as the Check screen reads it.
    func hasActiveAdjustment() async throws -> Bool
    /// Insulin on board for a counted dose, from Trio's newest determination of the 12 minutes up to `now`. Nil when there
    /// is none.
    func fetchDoseIOB(at now: Date) async throws -> Decimal?
}

/// Where settling is, from its last check, for the Settle step.
struct ISFTestSettlingProgress: Equatable {
    /// `ISFTestEvaluator.settling`.
    var decision: ISFTestSettling
    /// The boluses given while the test settles, oldest first (`ISFTestEvaluator.settlingBoluses`).
    var boluses: [ISFTestSettlingBolus]
    /// How many CGM readings came after Trio's first loop in Basal Testing (`ISFTestEvaluator.readingsAfterLoop`). Nil
    /// before that loop.
    var readingsAfterLoop: Int?
    /// Whether a temp basal was running on the pump, which holds settling up.
    var tempBasalRunning: Bool
    /// Insulin on board as the check read it, which `decision` was made from (`ISFTestEvaluator.waitsForIOB`), so the Settle
    /// step shows the number the step it shows rests on. Nil when Trio hadn't worked it out.
    var iob: Decimal? = nil
}

/// What the ISF runner publishes for its screen.
struct ISFTestRunnerState: Equatable {
    /// The test in progress or just finished, as saved. Nil with none.
    var test: ISFTestState?
    /// Settling's last check while the test settles. Nil otherwise, and before the first check.
    var settling: ISFTestSettlingProgress?
    /// Raising or dosing in a test that counts insulin on board: the last `fetchDoseIOB` read. Not saved.
    var doseIOB: Decimal? = nil
}

/// What Begin starts the test from, as the Check step read it.
struct ISFTestBegin: Equatable {
    /// The glucose the dose is worked out from at Begin (`ISFTestEvaluator.doseGlucose`), in mg/dL.
    var glucose: Int
    /// Insulin on board at Begin. Nil while Trio hasn't worked it out.
    var iob: Decimal?
    /// How the test handles insulin on board over its line, as picked on the Check screen.
    var iobChoice: ISFTestIOBHandling
}

/// The tablets the Raise step counted, as the user took them.
struct ISFTestTabletsTaken: Equatable {
    var brand: GlucoseTabletBrand
    var count: Int
    /// The glucose they were counted from, which glucose has to rise above before the dose. Nil without a recent reading.
    var glucose: Int?
}

/// A step of a running ISF test that waits on the user, as its notice says.
enum ISFTestStepNotice {
    /// Settling is done and the Dose step is next.
    case settledToDose
    /// Settling is done and tablets are next: the Raise step, or a Dose step that offers more tablets.
    case settledToRaise
    /// The tablets acted and glucose leveled off, so the Raise step moved on to the Dose step.
    case tabletsActed
    /// Settling's hour is up with insulin on board still over the line: the Settle step asks whether to count it and go
    /// on, or cancel (`ISFTestSettling.timeUp`).
    case timeUp
}

/// What the ISF screen asks of its runner.
protocol ISFTestRunning: AnyObject {
    var state: ISFTestRunnerState { get }
    var statePublisher: AnyPublisher<ISFTestRunnerState, Never> { get }
    @MainActor func begin(_ begin: ISFTestBegin) async -> SettingsTestBeginError?
    @MainActor func countAndGoOn()
    @MainActor func tabletsTaken(_ tablets: ISFTestTabletsTaken)
    /// Skip, Dose Now.
    @MainActor func moveToDose()
    /// Work Out My Dose, with what the Raise step read.
    @MainActor func workOutDose(_ inputs: ISFTestDoseInputs)
    @MainActor func raiseFirst()
    func endEarly() async
    /// Cancel Test.
    @MainActor func discard()
    /// Done.
    @MainActor func acknowledgeResult()
    func check() async
}

extension SettingsTestService {
    /// The ISF test's runner, while the service has one.
    var isfRunner: ISFTestRunning? { runner(for: .isf) as? ISFTestRunning }
}
