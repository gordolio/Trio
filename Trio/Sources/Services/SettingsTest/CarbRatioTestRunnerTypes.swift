import Combine
import Foundation

// What the carb ratio test's runner and its screen share: the reads, the state the runner publishes, and the actions the
// screen passes on (`CarbRatioTestRunner`), as the ISF test's are (`ISFTestRunnerTypes`).

/// What the carb ratio test reads, by its screen and by its runner with the screen closed. `CarbRatioTest.Provider`
/// conforms, so each read has one implementation, most of them the ISF test's.
protocol CarbRatioTestReads: AnyObject {
    /// The ISF schedule in mg/dL per unit, empty when there is none saved.
    func isfEntries() -> [SettingsTestScheduleEntry]
    /// The carb ratio schedule in grams per unit, empty when there is none saved.
    func carbRatioEntries() -> [SettingsTestScheduleEntry]
    func isf(at date: Date) -> Decimal?
    func target(at date: Date) -> Decimal?
    func carbRatio(at date: Date) -> Decimal?
    func currentIOB() -> Decimal?
    func currentCOB() async throws -> Decimal?
    func pumpDelivery() -> ISFTestPumpDelivery?
    func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading]
    func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading]
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
    /// The carb entries dated in the window, oldest first, with their grams, each with the same ID the service's watchdog
    /// reads it by (`SettingsTestEvents.carbEntries`), so Begin's kept entries and the test's own match it.
    func fetchCarbs(from start: Date, to end: Date) async throws -> [CarbRatioTestCarbs]
    /// Whether an override or a temp target is running, as the Check screen reads it.
    func hasActiveAdjustment() async throws -> Bool
    /// Insulin on board for a counted dose, from Trio's newest determination of the 12 minutes up to `now`. Nil when there
    /// is none.
    func fetchDoseIOB(at now: Date) async throws -> Decimal?
    /// Max Bolus in units, as the Treatments screen reads it. Nil when it can't be read.
    func maxBolus() -> Decimal?
    /// Max Carbs in grams, as the Treatments screen reads it. Nil when it can't be read.
    func maxCarbs() -> Decimal?
}

extension CarbRatioTestReads {
    /// Carbs on board for the Dose step, a docs rule ("Zero or minimal COB from previous meals"): from Trio's newest
    /// determination of the last 12 minutes (`currentCOB`), or, once the tablets' carbs are logged before the bolus
    /// (`CarbRatioTestEvaluator.mealCarbs` from `windowStart`), the newest from before them
    /// (`CarbRatioTestEvaluator.cobBefore`), so the tablets themselves aren't counted. Nil while unread: no bolus window
    /// yet, or a read that failed or found none that recent. What the runner and the screen both read.
    func fetchDoseCOB(windowStart: Date?, now: Date = Date()) async -> Decimal? {
        guard let windowStart else { return nil }
        do {
            let entries = try await fetchCarbs(
                from: windowStart,
                to: now.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
            )
            guard let logged = CarbRatioTestEvaluator.mealCarbs(entries, since: windowStart) else {
                return try await currentCOB()
            }
            let determinations = try await fetchDeterminations(
                from: logged.date.addingTimeInterval(
                    -BasalTest.Config.endReadingMaxAge - CarbRatioTest.Config.savedDateTolerance
                ),
                to: logged.date.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
            )
            return CarbRatioTestEvaluator.cobBefore(determinations, moment: logged.date)
        } catch {
            warning(.settings, "CarbRatioTest: couldn't read carbs on board for the dose", error: error)
            return nil
        }
    }
}

/// What the carb ratio runner publishes for its screen.
struct CarbRatioTestRunnerState: Equatable {
    /// The test in progress or just finished, as saved. Nil with none.
    var test: CarbRatioTestState?
    /// Settling's last check while the test settles. Nil otherwise, and before the first check.
    var settling: ISFTestSettlingProgress?
    /// Dosing in a test that counts insulin on board: the last `fetchDoseIOB` read. Not saved.
    var doseIOB: Decimal? = nil
}

/// What Begin starts the test from, as the Check step read it.
struct CarbRatioTestBegin: Equatable {
    var brand: GlucoseTabletBrand
    /// How many tablets, from 1 to what Max Bolus and Max Carbs allow (`CarbRatioTestEvaluator.tabletCount`).
    var count: Int
    /// How long the test runs after the bolus (`CarbRatioTest.Config.lengths`).
    var length: TimeInterval
    /// The glucose the Check step read, in mg/dL. Only logged: the start glucose is read at the bolus.
    var glucose: Int
    /// Insulin on board at Begin. Nil while Trio hasn't worked it out.
    var iob: Decimal?
    /// How the test handles insulin on board over its line, as picked on the Check screen. Nil when the screen didn't
    /// show the choice (its own `iobDecision` wasn't `.choice`): Begin then saves no handling, whatever it finds.
    var iobChoice: ISFTestIOBHandling?
}

/// A step of a running carb ratio test that waits on the user, as its notice says.
enum CarbRatioTestStepNotice: Equatable {
    /// Settling is done and the Dose step offers the dose.
    case settledToDose
    /// Settling's hour is up with insulin on board still over the line: the Settle step asks whether to count it and go
    /// on, or cancel (`ISFTestSettling.timeUp`).
    case timeUp
}

/// What the carb ratio screen asks of its runner.
protocol CarbRatioTestRunning: AnyObject {
    var state: CarbRatioTestRunnerState { get }
    var statePublisher: AnyPublisher<CarbRatioTestRunnerState, Never> { get }
    @MainActor func begin(_ begin: CarbRatioTestBegin) async -> SettingsTestBeginError?
    /// Count It and Go On, after settling's hour.
    @MainActor func countAndGoOn()
    /// End Test.
    func endEarly() async
    /// Cancel Test.
    @MainActor func discard()
    /// Done.
    @MainActor func acknowledgeResult()
    func check() async
}

extension SettingsTestService {
    /// The carb ratio test's runner, while the service has one.
    var carbRatioRunner: CarbRatioTestRunning? { runner(for: .carbRatio) as? CarbRatioTestRunning }
}
