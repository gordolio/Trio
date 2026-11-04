import CoreText
import Foundation
import LoopKit
import Testing
import UIKit

@testable import Trio

// MARK: - ISF test evaluation

@Suite("ISF test evaluator") struct ISFTestEvaluatorTests {
    private let hour: TimeInterval = 3600

    /// An exact decimal. A Decimal written as a literal goes through a Double, which makes 2.24 a hair more than 2.24.
    private func dec(_ string: String) -> Decimal { Decimal(string: string)! }

    /// The docs' Bill example: glucose 212, target 100, ISF 50, so a 2.24 U correction that should bring glucose to
    /// 100. One docs step (5%) of that 112 mg/dL drop is 5.6 mg/dL.
    private func evaluate(
        start: Int? = 212,
        end: Int?,
        units: Decimal? = Decimal(string: "2.24"),
        elapsedHours: Double = 4,
        reason: ISFTestEndReason = .completed,
        interference: String? = nil,
        interferenceUnread: Bool = false,
        isf: Decimal? = 50,
        target: Decimal? = 100,
        step: Decimal = ISFTest.Config.docsSmallestStep
    ) -> ISFTestEvaluator.Evaluation {
        ISFTestEvaluator.evaluate(
            startGlucose: start,
            endGlucose: end,
            units: units,
            elapsed: elapsedHours * hour,
            reason: reason,
            interference: interference,
            interferenceUnread: interferenceUnread,
            isf: isf,
            target: target,
            // Given as judged: the docs' 4 hours left nothing on board.
            givenUnits: units,
            step: step
        )
    }

    @Test("The docs' numbers: a 5% step, a 4 hour wait, aiming for around 150 mg/dL") func docsNumbers() {
        #expect(ISFTest.Config.docsSmallestStep == dec("0.05"))
        #expect(ISFTest.Config.docsWait == 4 * hour)
        #expect(ISFTest.Config.docsStartAim == 150)
    }

    @Test("The steps run check, settle, raise, dose, wait, result") func steps() {
        #expect(ISFTest.Step.allCases.map(\.title) == ["Check", "Settle", "Raise", "Dose", "Wait", "Result"])
        #expect(ISFTest.Step.allCases.map(\.iconName) == [
            "checklist", "hourglass", "arrow.up.circle", "syringe", "timer", "chart.line.uptrend.xyaxis"
        ])
        #expect(ISFTest.Step.allCases.map(\.order) == [0, 1, 2, 3, 4, 5])
    }

    // MARK: Dose

    @Test("The dose is the docs' formula, glucose minus target over ISF, to 2 decimals") func doseFromDocsFormula() {
        #expect(ISFTestEvaluator.dose(glucose: 212, target: 100, isf: 50) == dec("2.24"))
        // The docs' Bill example.
        #expect(ISFTestEvaluator.dose(glucose: 250, target: 100, isf: 50) == 3)
        // 2.2222… rounds to 2 decimals.
        #expect(ISFTestEvaluator.dose(glucose: 200, target: 100, isf: 45) == dec("2.22"))
    }

    @Test("At or below target the formula gives no dose, and neither does an ISF of zero") func noDoseAtOrBelowTarget() {
        #expect(ISFTestEvaluator.dose(glucose: 100, target: 100, isf: 50) == nil)
        #expect(ISFTestEvaluator.dose(glucose: 90, target: 100, isf: 50) == nil)
        #expect(ISFTestEvaluator.dose(glucose: 212, target: 100, isf: 0) == nil)
        #expect(ISFTestEvaluator.dose(glucose: 212, target: 100, isf: -50) == nil)
    }

    // MARK: Tablets

    @Test("Tablets bring glucose up to the aim: the rise needed, times the carb ratio, over the ISF") func tabletCarbsToAim() {
        // 40 mg/dL to rise ÷ ISF 50 = 0.8 U, which 10 g covers per unit: 8 g.
        let carbs = ISFTestEvaluator.tabletCarbs(glucose: 110, carbRatio: 10, isf: 50)
        #expect(carbs == 8)
        // Rounded up to whole tablets of the chosen brand: 2 of 4 g, 3 of 3.75 g.
        #expect(ISFTestEvaluator.tablets(for: carbs, brand: .dex4) == 2)
        #expect(ISFTestEvaluator.tablets(for: carbs, brand: .trueplus) == 3)
        // At the aim, or above it, there is nothing to raise.
        #expect(ISFTestEvaluator.tabletCarbs(glucose: 150, carbRatio: 10, isf: 50) == 0)
        #expect(ISFTestEvaluator.tabletCarbs(glucose: 160, carbRatio: 10, isf: 50) == 0)
        #expect(ISFTestEvaluator.tablets(for: 0, brand: .dex4) == 0)
    }

    @Test("Without a usable ISF or carb ratio there are no tablets to count") func tabletsNeedSettings() {
        #expect(ISFTestEvaluator.tabletCarbs(glucose: 110, carbRatio: 10, isf: 0) == 0)
        #expect(ISFTestEvaluator.tabletCarbs(glucose: 110, carbRatio: 0, isf: 50) == 0)
    }

    @Test("A part of a tablet counts as a whole one") func tabletsRoundUp() {
        // 40 mg/dL ÷ ISF 45 × CR 12 = 10.666… g, which is 2.67 Dex4 tablets.
        let carbs = ISFTestEvaluator.tabletCarbs(glucose: 110, carbRatio: 12, isf: 45)
        #expect(ISFTestEvaluator.tablets(for: carbs, brand: .dex4) == 3)
        #expect(ISFTestEvaluator.tablets(for: 4, brand: .dex4) == 1)
        #expect(ISFTestEvaluator.tablets(for: dec("4.01"), brand: .dex4) == 2)
        #expect(ISFTestEvaluator.tablets(for: -1, brand: .dex4) == 0)
    }

    // MARK: Result

    @Test("A drop per unit more than 5% under the ISF says the ISF is too high: lower it") func tooHighPastStep() throws {
        let result = evaluate(end: 120)
        #expect(result.outcome == .tooHigh)
        #expect(result.direction == .decrease)
        // 92 mg/dL ÷ 2.24 U = 41.07 mg/dL per unit against an ISF of 50.
        let share = try #require(result.share)
        #expect(BasalTestEvaluator.wholePercent(share) == -17)
        let drop = try #require(result.dropPerUnit)
        #expect(BasalTestEvaluator.towardZero(drop, scale: 1) == 41)
    }

    @Test("A drop per unit within 5% of the ISF says the ISF is accurate") func accurateUnderStep() {
        let result = evaluate(end: 102)
        #expect(result.outcome == .accurate)
        #expect(result.direction == .keep)
        #expect(result.share.map(BasalTestEvaluator.wholePercent) == -1)
    }

    @Test("A drop per unit more than 5% over the ISF says the ISF is too low: raise it") func tooLowPastStep() throws {
        let result = evaluate(end: 80)
        #expect(result.outcome == .tooLow)
        #expect(result.direction == .increase)
        let share = try #require(result.share)
        #expect(BasalTestEvaluator.wholePercent(share) == 17)
    }

    @Test("The result is per unit actually given, so a smaller dose still passes above target") func resultPerUnitGiven() {
        // 1.79 U instead of 2.24: glucose lands above the 100 target, but 89 mg/dL ÷ 1.79 U is 49.7 per unit.
        let result = evaluate(end: 123, units: dec("1.79"))
        #expect(result.outcome == .accurate)
        #expect(result.direction == .keep)
    }

    @Test("A change of exactly one docs step is a change, not accurate") func exactlyOneStepIsAChange() {
        // 95 mg/dL ÷ 2 U = 47.5 per unit against 50: exactly -5%.
        let result = evaluate(start: 200, end: 105, units: 2)
        #expect(result.share == dec("-0.05"))
        #expect(result.outcome == .tooHigh)
        #expect(result.direction == .decrease)
        // And the same distance the other way: 52.5 per unit.
        let other = evaluate(start: 200, end: 95, units: 2)
        #expect(other.share == dec("0.05"))
        #expect(other.outcome == .tooLow)
        // Just inside the step keeps.
        #expect(evaluate(start: 200, end: 104, units: 2).outcome == .accurate)
    }

    @Test("Glucose that rose after the bolus says the ISF is too high") func glucoseRoseIsTooHigh() throws {
        let result = evaluate(end: 230)
        #expect(result.outcome == .tooHigh)
        #expect(result.direction == .decrease)
        let drop = try #require(result.dropPerUnit)
        #expect(drop < 0)
    }

    @Test("A low at or below the target ends the test with raise the ISF, and no working") func lowIsTooLow() {
        let result = evaluate(end: 60, elapsedHours: 1, reason: .low)
        #expect(result.outcome == .tooLow)
        #expect(result.direction == .increase)
        #expect(result.dropPerUnit == nil)
        #expect(result.share == nil)
        // At the target is below it for the docs' line, which a low follows.
        #expect(evaluate(end: 100, elapsedHours: 1, reason: .low).outcome == .tooLow)
        // Without the glucose at the suspend, or the units given, it can't be told from a forecast suspend or a bigger
        // bolus, so there is no verdict.
        #expect(evaluate(start: nil, end: nil, units: nil, elapsedHours: 1, reason: .low, isf: nil).outcome == .inconclusive)
        #expect(evaluate(end: nil, elapsedHours: 1, reason: .low).outcome == .inconclusive)
        #expect(evaluate(end: 60, units: nil, elapsedHours: 1, reason: .low).outcome == .inconclusive)
        #expect(evaluate(end: 60, elapsedHours: 1, reason: .low, target: nil).outcome == .inconclusive)
    }

    @Test("Ending early, or before the docs' 4 hours, says nothing") func shortOrEndedEarlyIsInconclusive() {
        let early = evaluate(end: 100, elapsedHours: 2, reason: .endedEarly)
        #expect(early.outcome == .inconclusive)
        #expect(early.direction == nil)
        #expect(evaluate(end: 100, elapsedHours: 4, reason: .endedEarly).outcome == .inconclusive)
        #expect(evaluate(end: 100, elapsedHours: 3.9).outcome == .inconclusive)
        // The pump history couldn't be read, so a low can't be ruled out.
        #expect(evaluate(end: 100, elapsedHours: 4, reason: .unchecked).outcome == .inconclusive)
        // Exactly the 4 hours is enough.
        #expect(evaluate(end: 100, elapsedHours: 4).outcome == .accurate)
        #expect(!ISFTestOutcome.inconclusive.isConclusive)
    }

    @Test("Without a reading or setting to compare there is no result") func noEndReadingIsInconclusive() {
        #expect(evaluate(end: nil).outcome == .inconclusive)
        #expect(evaluate(start: nil, end: 100).outcome == .inconclusive)
        #expect(evaluate(end: 100, units: nil).outcome == .inconclusive)
        #expect(evaluate(end: 100, units: 0).outcome == .inconclusive)
        #expect(evaluate(end: 100, isf: nil).outcome == .inconclusive)
        #expect(evaluate(end: 100, isf: 0).outcome == .inconclusive)
        #expect(evaluate(end: nil).direction == nil)
    }

    @Test("Interference, an interrupted test or no bolus makes the result unusable") func interruptedIsInvalid() {
        let interrupted = evaluate(end: 100, reason: .interrupted)
        #expect(interrupted.outcome == .invalid)
        #expect(interrupted.direction == nil)
        #expect(evaluate(end: 100, interference: "Carbs were logged").outcome == .invalid)
        #expect(evaluate(start: nil, end: nil, units: nil, elapsedHours: 1.5, reason: .noBolus, isf: nil).outcome == .invalid)
        // Invalid comes before a low and before ending early.
        #expect(evaluate(end: 60, elapsedHours: 1, reason: .low, interference: "Another bolus").outcome == .invalid)
        #expect(evaluate(end: 60, elapsedHours: 1, reason: .endedEarly, interference: "Another bolus").outcome == .invalid)
        #expect(!ISFTestOutcome.invalid.isConclusive)
    }

    @Test(
        "A record that couldn't be read for what spoils the test leaves it inconclusive, a low among them"
    ) func unreadInterferenceIsInconclusive() {
        // Glucose fell more than the ISF says, but carbs or a bolus may have been missed.
        let unread = evaluate(end: 60, interferenceUnread: true)
        #expect(unread.outcome == .inconclusive)
        #expect(unread.direction == nil)
        #expect(unread.dropPerUnit == nil)
        #expect(evaluate(end: 100, interferenceUnread: true).outcome == .inconclusive)
        #expect(evaluate(end: 60, elapsedHours: 1, reason: .low, interferenceUnread: true).outcome == .inconclusive)
        // Something found, or an interrupted test, is still invalid.
        #expect(evaluate(end: 100, interference: "Carbs were logged", interferenceUnread: true).outcome == .invalid)
        #expect(evaluate(end: 100, reason: .interrupted, interferenceUnread: true).outcome == .invalid)
        // Read in full, the same test has a verdict.
        #expect(evaluate(end: 100, interferenceUnread: false).outcome == .accurate)
    }

    @Test("Only a verdict on the ISF is conclusive") func conclusive() {
        #expect(ISFTestOutcome.accurate.isConclusive)
        #expect(ISFTestOutcome.tooHigh.isConclusive)
        #expect(ISFTestOutcome.tooLow.isConclusive)
        #expect(!ISFTestOutcome.inconclusive.isConclusive)
        #expect(!ISFTestOutcome.invalid.isConclusive)
    }

    // MARK: Expected end

    @Test("The accurate ends are the start less the dose's drop, give or take just under a docs step") func expectedEndBand() {
        // 2.24 U × ISF 50 = 112 mg/dL, so glucose should end at 100. One step is 5.6, so 5 either side.
        #expect(ISFTestEvaluator.accurateEnds(startGlucose: 212, units: dec("2.24"), isf: 50) == 95 ... 105)
        // A step that lands on a whole number is itself outside the band: 2 U × 50 × 5% = 5.
        #expect(ISFTestEvaluator.accurateEnds(startGlucose: 200, units: 2, isf: 50) == 96 ... 104)
        let tenPercent = ISFTestEvaluator.accurateEnds(startGlucose: 212, units: dec("2.24"), isf: 50, step: dec("0.10"))
        #expect(tenPercent == 89 ... 111)
    }

    @Test("The band holds exactly the end readings the verdict calls accurate") func expectedEndBandMatchesVerdict() throws {
        // A dose times the ISF that isn't a whole number puts the expected end between two readings.
        let cases: [(start: Int, units: Decimal, isf: Decimal)] = [
            (212, dec("2.24"), 50), (212, dec("2.01"), 50), (212, dec("1.79"), 50), (250, 3, 45),
            (300, dec("4.37"), dec("37.5")), (180, dec("0.5"), 50)
        ]
        for item in cases {
            let band = try #require(ISFTestEvaluator.accurateEnds(startGlucose: item.start, units: item.units, isf: item.isf))
            let centre = band.lowerBound + (band.upperBound - band.lowerBound) / 2
            for end in (centre - 40) ... (centre + 40) {
                let verdict = ISFTestEvaluator.evaluate(
                    startGlucose: item.start,
                    endGlucose: end,
                    units: item.units,
                    elapsed: 4 * hour,
                    reason: .completed,
                    interference: nil,
                    isf: item.isf
                ).outcome
                #expect(
                    band.contains(end) == (verdict == .accurate),
                    "start \(item.start), \(item.units) U, ISF \(item.isf), end \(end): \(verdict), band \(band)"
                )
            }
        }
    }

    // MARK: A running test

    /// When the test started, on a whole second.
    private let testStart = Date(timeIntervalSince1970: 1_800_000_000)
    /// The session the running test started with.
    private let testSession = UUID(uuidString: "5C1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    /// The bolus is due within the ISF test's allowance of Start.
    private var doseDeadline: Date { testStart.addingTimeInterval(ISFTest.Config.doseAllowance) }
    /// The bolus went in 20 minutes after Start, so the 4 hours end 4 hours after that.
    private var plannedEnd: Date { testStart.addingTimeInterval(20 * 60 + ISFTest.Config.docsWait) }

    private func at(_ seconds: TimeInterval) -> Date { testStart.addingTimeInterval(seconds) }

    private func bolus(_ seconds: TimeInterval, _ units: String = "2.24") -> ISFTestBolus {
        ISFTestBolus(date: at(seconds), units: dec(units))
    }

    private func serviceEnd(
        _ cause: SettingsTestEndCause,
        after seconds: TimeInterval,
        session: UUID? = nil
    ) -> SettingsTestEnd {
        SettingsTestEnd(sessionID: session ?? testSession, cause: cause, date: at(seconds))
    }

    /// `now` and the times in `ended` and `suspend` are seconds after Start.
    private func check(
        _ phase: ISFTestPhase,
        ended: SettingsTestEnd? = nil,
        sessionID: UUID? = nil,
        suspend: TimeInterval? = nil,
        unexplained: TimeInterval? = nil,
        unreadable: Bool = false,
        now: TimeInterval,
        withoutPlannedEnd: Bool = false,
        bolusAt: TimeInterval? = 20 * 60,
        mode: DosingMode = .basalTesting
    ) -> ISFTestEvaluator.RunningCheck? {
        // `suspend` is a zero temp one of Trio's determinations asked for; `unexplained`, one none of them did.
        let reading: BasalTestEvaluator.SuspendReading
        if unreadable {
            reading = .unreadable
        } else if let suspend {
            reading = .suspended(at: at(suspend))
        } else if let unexplained {
            reading = .unexplained(at: at(unexplained))
        } else {
            reading = .none
        }
        return ISFTestEvaluator.runningCheck(
            phase: phase,
            sessionID: sessionID ?? testSession,
            serviceEnd: ended,
            suspend: reading,
            now: at(now),
            doseDeadline: doseDeadline,
            // Only a test that is waiting has a bolus and a planned end, 4 hours after it.
            bolusAt: phase == .waiting && !withoutPlannedEnd ? bolusAt.map(at) : nil,
            plannedEnd: phase == .waiting && !withoutPlannedEnd ? plannedEnd : nil,
            mode: mode
        )
    }

    @Test("The phases are settling, raising, dosing, waiting and finished, and keep their names on disk") func phases() {
        #expect(["settling", "raising", "dosing", "waiting", "finished"].compactMap { ISFTestPhase(rawValue: $0) } == [
            .settling, .raising, .dosing, .waiting, .finished
        ])
        #expect(["wait", "count"].compactMap { ISFTestIOBHandling(rawValue: $0) } == [.wait, .count])
    }

    @Test("The test bolus is the earliest manual bolus from Start to the deadline") func findsFirstManualBolus() {
        let boluses = [
            // Before Start: an earlier correction, not this test's.
            bolus(-600, "1"),
            // Later than the first one in the window, listed first to show order doesn't matter.
            bolus(2400, "0.5"),
            bolus(1200, "2.24"),
            // After the deadline.
            bolus(ISFTest.Config.doseAllowance + 60, "3")
        ]
        let found = ISFTestEvaluator.testBolus(boluses, since: testStart, deadline: doseDeadline)
        #expect(found == bolus(1200, "2.24"))
    }

    @Test("A bolus exactly at Start or at the deadline counts") func bolusAtTheEdgesCounts() {
        #expect(ISFTestEvaluator.testBolus([bolus(0)], since: testStart, deadline: doseDeadline) == bolus(0))
        #expect(
            ISFTestEvaluator.testBolus([bolus(ISFTest.Config.doseAllowance)], since: testStart, deadline: doseDeadline)
                == bolus(ISFTest.Config.doseAllowance)
        )
    }

    @Test("No bolus in the window gives no test bolus") func noTestBolus() {
        #expect(ISFTestEvaluator.testBolus([], since: testStart, deadline: doseDeadline) == nil)
        #expect(
            ISFTestEvaluator.testBolus(
                [bolus(-1), bolus(ISFTest.Config.doseAllowance + 1)],
                since: testStart,
                deadline: doseDeadline
            ) == nil
        )
    }

    @Test("No bolus by the deadline ends the test with no bolus, whatever the mode is") func noBolusByDeadline() {
        let deadline = ISFTest.Config.doseAllowance
        for phase in [ISFTestPhase.raising, .dosing] {
            #expect(check(phase, now: deadline - 1) == nil)
            #expect(check(phase, now: deadline) == .noBolus)
            #expect(check(phase, now: deadline + 600) == .noBolus)
            // Out of time comes before a mode that was changed, and before a suspend.
            #expect(check(phase, suspend: 600, now: deadline, mode: .closed) == .noBolus)
        }
    }

    @Test("A suspend before the bolus ends the test with nothing to judge") func lowBeforeDoseEnds() {
        for phase in [ISFTestPhase.raising, .dosing] {
            #expect(check(phase, suspend: 600, now: 1800) == .lowBeforeDose(at: at(600)))
        }
    }

    @Test("A mode changed before the bolus ends the test, even with a zero temp in it") func modeChangedBeforeBolus() {
        for phase in [ISFTestPhase.raising, .dosing] {
            #expect(check(phase, now: 600, mode: .closed) == .modeChanged)
            #expect(check(phase, now: 600, mode: .lowGlucoseSuspend) == .modeChanged)
            // A zero temp the new mode set is not a low.
            #expect(check(phase, suspend: 300, now: 600, mode: .closed) == .modeChanged)
        }
    }

    @Test("Before the bolus the test keeps going, whether or not the pump history could be read") func beforeBolusKeepsGoing() {
        for phase in [ISFTestPhase.raising, .dosing] {
            #expect(check(phase, now: 600) == nil)
            #expect(check(phase, unreadable: true, now: 600) == nil)
        }
    }

    @Test("A test that has finished has nothing left to check") func finishedChecksNothing() {
        #expect(check(.finished, ended: serviceEnd(.low, after: 600), now: 7200, mode: .closed) == nil)
        #expect(check(.finished, suspend: 600, now: 7200) == nil)
    }

    @Test("The service's record before the bolus ends the test for the cause it recorded") func serviceEndBeforeBolus() {
        for phase in [ISFTestPhase.raising, .dosing] {
            // A low before the bolus leaves nothing to judge, and the usual mode is already back.
            #expect(check(phase, ended: serviceEnd(.low, after: 600), now: 900, mode: .closed) == .lowBeforeDose(at: at(600)))
            #expect(
                check(phase, ended: serviceEnd(.carbsLogged, after: 600), now: 900, mode: .closed)
                    == .carbsLogged(at: at(600))
            )
            #expect(
                check(phase, ended: serviceEnd(.extraBolus, after: 600), now: 900, mode: .closed)
                    == .extraBolus(at: at(600))
            )
            // It needs no pump history, and it beats a zero temp the next mode set later.
            #expect(
                check(phase, ended: serviceEnd(.low, after: 600), suspend: 700, now: 900, mode: .closed)
                    == .lowBeforeDose(at: at(600))
            )
        }
    }

    @Test("A record dated at the dose deadline decides, one dated after it doesn't") func serviceEndAtTheDeadline() {
        let deadline = ISFTest.Config.doseAllowance
        #expect(
            check(.dosing, ended: serviceEnd(.carbsLogged, after: deadline), now: deadline + 60, mode: .closed)
                == .carbsLogged(at: doseDeadline)
        )
        // Found after the time for the bolus was up: no bolus came.
        #expect(
            check(.dosing, ended: serviceEnd(.carbsLogged, after: deadline + 1), now: deadline + 60, mode: .closed)
                == .noBolus
        )
    }

    @Test("A record of another session, or with no session to match, isn't this test's") func serviceEndOtherSession() {
        let other = serviceEnd(.low, after: 600, session: UUID())
        #expect(check(.dosing, ended: other, now: 900, mode: .closed) == .modeChanged)
        #expect(check(.waiting, ended: other, now: 3600, mode: .closed) == .modeChanged)
        #expect(
            ISFTestEvaluator.runningCheck(
                phase: .dosing,
                sessionID: nil,
                serviceEnd: serviceEnd(.low, after: 600),
                suspend: .none,
                now: at(900),
                doseDeadline: doseDeadline,
                bolusAt: nil,
                plannedEnd: nil,
                mode: .closed
            ) == .modeChanged
        )
    }

    @Test("Waiting, the service ending the test for a low is a low, with the usual mode already back") func serviceLowWhileWaiting() {
        #expect(check(.waiting, ended: serviceEnd(.low, after: 3600), now: 7200, mode: .closed) == .low(at: at(3600)))
        // It still holds once the planned time is up, and when the pump history can't be read.
        #expect(check(.waiting, ended: serviceEnd(.low, after: 3600), now: 5 * hour, mode: .closed) == .low(at: at(3600)))
        #expect(
            check(.waiting, ended: serviceEnd(.low, after: 3600), unreadable: true, now: 7200, mode: .closed)
                == .low(at: at(3600))
        )
        // One at the planned end is still inside the wait.
        #expect(
            check(.waiting, ended: serviceEnd(.low, after: 20 * 60 + 4 * hour), now: 5 * hour, mode: .closed)
                == .low(at: plannedEnd)
        )
    }

    @Test(
        "Waiting, logged carbs and a second bolus end the test at the time the service recorded"
    ) func serviceInterruptionWhileWaiting() {
        #expect(
            check(.waiting, ended: serviceEnd(.carbsLogged, after: 3600), now: 7200, mode: .closed)
                == .carbsLogged(at: at(3600))
        )
        #expect(
            check(.waiting, ended: serviceEnd(.extraBolus, after: 3600), now: 7200, mode: .closed)
                == .extraBolus(at: at(3600))
        )
    }

    @Test("A record from after the planned end says nothing about a wait that had run its course") func serviceEndAfterPlannedEnd() {
        let late = 20 * 60 + 4 * hour + 60
        #expect(check(.waiting, ended: serviceEnd(.low, after: late), now: 5 * hour, mode: .closed) == .completed)
        #expect(check(.waiting, ended: serviceEnd(.carbsLogged, after: late), now: 5 * hour, mode: .closed) == .completed)
        #expect(check(.waiting, ended: serviceEnd(.extraBolus, after: late), now: 5 * hour, mode: .closed) == .completed)
    }

    @Test("Waiting, the time up completes the test even when the usual mode came back") func completedWhileClosed() {
        let end = 20 * 60 + 4 * hour
        #expect(check(.waiting, now: end, mode: .closed) == .completed)
        #expect(check(.waiting, now: end + 1800, mode: .closed) == .completed)
        #expect(check(.waiting, now: end) == .completed)
        // Not yet.
        #expect(check(.waiting, now: end - 1) == nil)
    }

    @Test("Waiting, time up with no readable pump history still ends the test, without a verdict") func waitingUnreadable() {
        let end = 20 * 60 + 4 * hour
        #expect(check(.waiting, unreadable: true, now: end) == .completedUnchecked)
        #expect(check(.waiting, unreadable: true, now: end, mode: .closed) == .completedUnchecked)
        #expect(check(.waiting, unreadable: true, now: end - 60) == nil)
    }

    @Test(
        "Waiting, a mode changed before the planned end interrupts the test, even with a zero temp in it"
    ) func waitingModeChanged() {
        #expect(check(.waiting, now: 3600, mode: .closed) == .modeChanged)
        #expect(check(.waiting, suspend: 1800, now: 3600, mode: .lowGlucoseSuspend) == .modeChanged)
    }

    @Test("Waiting, a zero temp is a low only while Basal Testing is still on") func waitingLow() {
        #expect(check(.waiting, suspend: 1800, now: 3600) == .low(at: at(1800)))
        #expect(check(.waiting, suspend: 1800, now: 5 * hour) == .low(at: at(1800)))
        // Off by now, with no record from the service: it can't be told whose zero temp it was.
        #expect(check(.waiting, suspend: 1800, now: 5 * hour, mode: .closed) == .unexplainedSuspend(at: at(1800)))
    }

    @Test(
        "Before the bolus, a zero temp none of Trio's determinations asked for interrupts the test, and isn't a low"
    ) func unaskedZeroTempBeforeBolus() {
        for phase in [ISFTestPhase.raising, .dosing] {
            #expect(check(phase, unexplained: 600, now: 1800) == .unexplainedSuspend(at: at(600)))
            // Out of time and a mode that was changed still come first, as for Trio's own suspend.
            #expect(check(phase, unexplained: 600, now: ISFTest.Config.doseAllowance) == .noBolus)
            #expect(check(phase, unexplained: 300, now: 600, mode: .closed) == .modeChanged)
        }
    }

    @Test(
        "Waiting, a zero temp Trio didn't ask for interrupts the test at the stop, in any mode"
    ) func unaskedZeroTempWhileWaiting() {
        #expect(check(.waiting, unexplained: 1800, now: 3600) == .unexplainedSuspend(at: at(1800)))
        // Before the bolus too: basal stopped inside the test is no low before the dose.
        #expect(check(.waiting, unexplained: 600, now: 3600) == .unexplainedSuspend(at: at(600)))
        #expect(check(.waiting, unexplained: 1800, now: 5 * hour) == .unexplainedSuspend(at: at(1800)))
        #expect(check(.waiting, unexplained: 1800, now: 5 * hour, mode: .closed) == .unexplainedSuspend(at: at(1800)))
        // Before the planned end a changed mode still comes first.
        #expect(check(.waiting, unexplained: 1800, now: 3600, mode: .closed) == .modeChanged)
    }

    @Test(
        "The service's record of basal stopped or unreadable carbs interrupts the test at the time it recorded"
    ) func serviceEndBasalStoppedOrCarbsUnreadable() {
        for phase in [ISFTestPhase.raising, .dosing] {
            #expect(
                check(phase, ended: serviceEnd(.basalStopped, after: 600), now: 900, mode: .closed)
                    == .unexplainedSuspend(at: at(600))
            )
            #expect(
                check(phase, ended: serviceEnd(.carbsUnreadable, after: 600), now: 900, mode: .closed)
                    == .carbsUnreadable(at: at(600))
            )
        }
        #expect(
            check(.waiting, ended: serviceEnd(.basalStopped, after: 3600), now: 7200, mode: .closed)
                == .unexplainedSuspend(at: at(3600))
        )
        #expect(
            check(.waiting, ended: serviceEnd(.carbsUnreadable, after: 3600), now: 7200, mode: .closed)
                == .carbsUnreadable(at: at(3600))
        )
        // One from after the planned end says nothing about a wait that had run its course.
        let late = 20 * 60 + 4 * hour + 60
        #expect(check(.waiting, ended: serviceEnd(.basalStopped, after: late), now: 5 * hour, mode: .closed) == .completed)
        #expect(check(.waiting, ended: serviceEnd(.carbsUnreadable, after: late), now: 5 * hour, mode: .closed) == .completed)
    }

    @Test(
        "Waiting without a planned end can't be judged: it closes with no verdict at the dose deadline"
    ) func waitingWithoutPlannedEnd() {
        let deadline = ISFTest.Config.doseAllowance
        #expect(check(.waiting, now: deadline - 1, withoutPlannedEnd: true) == nil)
        // Never `.completed`, which is a verdict.
        #expect(check(.waiting, now: deadline, withoutPlannedEnd: true) == .completedUnchecked)
        #expect(check(.waiting, now: deadline + 600, withoutPlannedEnd: true, mode: .closed) == .completedUnchecked)
        #expect(check(.waiting, unreadable: true, now: deadline, withoutPlannedEnd: true) == .completedUnchecked)
        // Whatever ended it before then still does, with no bolus time to tell a low before it from one after.
        #expect(
            check(.waiting, ended: serviceEnd(.low, after: 600), now: deadline - 1, withoutPlannedEnd: true, mode: .closed)
                == .low(at: at(600))
        )
    }

    @Test("Waiting, a low from before the bolus is a low before the dose, not one after it") func lowBeforeTheBolusWhileWaiting() {
        // The test ended for a low at 600 s with the screen closed, and the bolus went in at 1200 s from Home.
        #expect(
            check(.waiting, ended: serviceEnd(.low, after: 600), now: 3600, mode: .closed) == .lowBeforeDose(at: at(600))
        )
        #expect(
            check(.waiting, ended: serviceEnd(.low, after: 600), now: 5 * hour, mode: .closed)
                == .lowBeforeDose(at: at(600))
        )
        // The same for a zero temp with Basal Testing still on.
        #expect(check(.waiting, suspend: 600, now: 3600) == .lowBeforeDose(at: at(600)))
        #expect(check(.waiting, suspend: 600, now: 5 * hour) == .lowBeforeDose(at: at(600)))
        // A low after the bolus is still a low, and so is one at the same moment.
        #expect(check(.waiting, ended: serviceEnd(.low, after: 1800), now: 3600, mode: .closed) == .low(at: at(1800)))
        #expect(check(.waiting, suspend: 1800, now: 3600) == .low(at: at(1800)))
        #expect(check(.waiting, ended: serviceEnd(.low, after: 1200), now: 3600, mode: .closed) == .low(at: at(1200)))
        #expect(check(.waiting, suspend: 1200, now: 3600) == .low(at: at(1200)))
        // With no bolus time there is nothing to compare it with.
        #expect(
            check(.waiting, ended: serviceEnd(.low, after: 600), now: 3600, bolusAt: nil, mode: .closed) == .low(at: at(600))
        )
    }

    @Test("A service end for no bolus is no bolus, before the bolus") func serviceEndNoBolus() {
        let deadline = ISFTest.Config.doseAllowance
        for phase in [ISFTestPhase.raising, .dosing] {
            // Dated at the deadline, as the service dates it, and read before the screen's own clock gets there.
            #expect(check(phase, ended: serviceEnd(.noBolus, after: deadline), now: deadline - 1, mode: .closed) == .noBolus)
            #expect(check(phase, ended: serviceEnd(.noBolus, after: deadline), now: deadline + 600, mode: .closed) == .noBolus)
            // A record of another session isn't this test's.
            #expect(
                check(phase, ended: serviceEnd(.noBolus, after: deadline, session: UUID()), now: deadline - 1, mode: .closed)
                    == .modeChanged
            )
        }
    }

    @Test(
        "A service end for no bolus found once the bolus is in says Trio didn't see the bolus in time"
    ) func serviceEndNoBolusWhileWaiting() {
        // The bolus got into the pump history after the service looked: the usual mode was already back.
        #expect(
            check(.waiting, ended: serviceEnd(.noBolus, after: ISFTest.Config.doseAllowance), now: 7200, mode: .closed)
                == .bolusNotSeen
        )
        // Even once the 4 hours are up, and without a readable pump history.
        #expect(
            check(.waiting, ended: serviceEnd(.noBolus, after: ISFTest.Config.doseAllowance), now: 5 * hour, mode: .closed)
                == .bolusNotSeen
        )
        #expect(
            check(
                .waiting,
                ended: serviceEnd(.noBolus, after: ISFTest.Config.doseAllowance),
                unreadable: true,
                now: 7200,
                mode: .closed
            ) == .bolusNotSeen
        )
        // Another session's record isn't this test's.
        #expect(
            check(
                .waiting,
                ended: serviceEnd(.noBolus, after: ISFTest.Config.doseAllowance, session: UUID()),
                now: 7200,
                mode: .closed
            ) == .modeChanged
        )
    }

    @Test("A bolus recorded at 0 U gave no insulin and isn't one; one with no amount still is") func zeroUnitBolus() {
        #expect(ISFTestBolus(date: testStart, amount: 0) == nil)
        #expect(ISFTestBolus(date: testStart, amount: dec("0.00")) == nil)
        #expect(ISFTestBolus(date: testStart, amount: dec("2.24")) == bolus(0, "2.24"))
        #expect(ISFTestBolus(date: testStart, amount: nil) == ISFTestBolus(date: testStart, units: 0))
    }

    // MARK: The screen's state and decisions

    /// Times of day read in UTC, so the schedule tests mean the same on any machine.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func time(_ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: hour, minute: minute, second: second))!
    }

    private func entry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
        SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
    }

    @Test("A test saved while waiting comes back the same, with its deadline and planned end") func decodesSavedState() throws {
        var state = ISFTestState(
            phase: .waiting,
            startedAt: testStart,
            previousMode: .closed,
            isf: 50,
            target: 100,
            carbRatio: 10
        )
        state.sessionID = testSession
        state.tabletBrand = GlucoseTabletBrand.dex4.rawValue
        state.tabletCarbs = 8
        state.tabletsTakenAt = at(300)
        state.bolusAt = at(1200)
        state.bolusUnits = dec("2.24")
        state.startGlucose = 212
        state.coveredEntries = [entry(0, 360, 50), entry(360, 1440, 45)]
        state.readings = [BasalTestReading(date: at(1500), glucose: 205)]

        let decoded = try JSONCoding.decoder.decode(ISFTestState.self, from: JSONCoding.encoder.encode(state))
        #expect(decoded == state)
        #expect(decoded.phase == .waiting)
        #expect(decoded.doseDeadline == testStart.addingTimeInterval(ISFTest.Config.doseAllowance))
        #expect(decoded.plannedEnd == at(1200).addingTimeInterval(ISFTest.Config.docsWait))

        // Before the bolus there are no 4 hours running yet.
        let dosing = ISFTestState(phase: .dosing, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        let decodedDosing = try JSONCoding.decoder.decode(ISFTestState.self, from: JSONCoding.encoder.encode(dosing))
        #expect(decodedDosing == dosing)
        #expect(decodedDosing.plannedEnd == nil)
        #expect(decodedDosing.carbRatio == nil)
        #expect(decodedDosing.readings.isEmpty)
    }

    @Test("A target saved in mmol/L is used in mg/dL, one in mg/dL as it is") func targetFromMmol() {
        let mmol = BGTargets(
            units: .mmolL,
            userPreferredUnits: .mmolL,
            targets: [BGTargetEntry(low: 5.5, high: 5.5, start: "00:00", offset: 0)]
        )
        #expect(ISFTest.Provider.target(in: mmol, at: Date()) == Decimal(5.5).asMgdL)
        let mgdl = BGTargets(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            targets: [BGTargetEntry(low: 100, high: 110, start: "00:00", offset: 0)]
        )
        // The low end, as Trio's own target.
        #expect(ISFTest.Provider.target(in: mgdl, at: Date()) == 100)
        let none = BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        #expect(ISFTest.Provider.target(in: none, at: Date()) == nil)
    }

    @Test("The carb ratio is the entry in effect at the time") func carbRatioInEffect() {
        let ratios = CarbRatios(units: .grams, schedule: [
            CarbRatioEntry(start: "00:00", offset: 0, ratio: 10),
            CarbRatioEntry(start: "06:00", offset: 360, ratio: 12)
        ])
        #expect(ISFTest.Provider.carbRatio(in: ratios, at: time(5, 59), calendar: utc) == 10)
        #expect(ISFTest.Provider.carbRatio(in: ratios, at: time(6), calendar: utc) == 12)
        #expect(ISFTest.Provider.carbRatio(in: ratios, at: time(23, 59), calendar: utc) == 12)
        // Exchanges become grams per unit, as Trio's own lookup does (12 g an exchange).
        let exchanges = CarbRatios(units: .exchanges, schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: 1)])
        #expect(ISFTest.Provider.carbRatio(in: exchanges, at: time(12), calendar: utc) == 12)
        let none = CarbRatios(units: .grams, schedule: [])
        #expect(ISFTest.Provider.carbRatio(in: none, at: time(12), calendar: utc) == nil)
    }

    @Test("Hours that cross from one ISF to another are flagged, across midnight too") func flagsISFChangeInWindow() {
        let schedule = [entry(0, 300, 40), entry(300, 360, 50), entry(360, 1440, 45)]
        // 05:00 → 50 and 06:00 → 45: 4 hours from 05:00 cross 06:00.
        #expect(ISFTestEvaluator.crossesISFChange(schedule, from: time(5), for: 4 * hour, calendar: utc))
        // Inside one entry.
        #expect(!ISFTestEvaluator.crossesISFChange(schedule, from: time(6, 30), for: 4 * hour, calendar: utc))
        #expect(!ISFTestEvaluator.crossesISFChange(schedule, from: time(5, 10), for: 30 * 60, calendar: utc))
        // Ending exactly where the next entry starts doesn't reach it.
        #expect(!ISFTestEvaluator.crossesISFChange(schedule, from: time(5), for: hour, calendar: utc))
        // Wrapping midnight: 22:00 is 45, 00:00 is 40.
        #expect(ISFTestEvaluator.crossesISFChange(schedule, from: time(22), for: 4 * hour, calendar: utc))
        // Two entries with the same number are one ISF, across midnight or not.
        let sameEitherSide = [entry(0, 360, 45), entry(360, 1320, 50), entry(1320, 1440, 45)]
        #expect(!ISFTestEvaluator.crossesISFChange(sameEitherSide, from: time(23), for: 4 * hour, calendar: utc))
        let split = [entry(0, 720, 50), entry(720, 1440, 50)]
        #expect(!ISFTestEvaluator.crossesISFChange(split, from: time(10), for: 4 * hour, calendar: utc))
        #expect(!ISFTestEvaluator.crossesISFChange([], from: time(10), for: 4 * hour, calendar: utc))
    }

    @Test(
        "The entries a test covers are the ones its hours touch, under a minute the one it started in"
    ) func coveredEntriesOverWindow() {
        let schedule = [entry(0, 360, 50), entry(360, 1440, 45)]
        #expect(ISFTestEvaluator.coveredEntries(schedule, from: time(5), to: time(9), calendar: utc) == schedule)
        #expect(ISFTestEvaluator.coveredEntries(schedule, from: time(7), to: time(11), calendar: utc) == [entry(360, 1440, 45)])
        #expect(ISFTestEvaluator.coveredEntries(schedule, from: time(22), to: time(2), calendar: utc) == schedule)
        // A low seconds after the bolus covers the entry it came in, not the whole day.
        #expect(
            ISFTestEvaluator.coveredEntries(schedule, from: time(5, 59), to: time(5, 59, second: 30), calendar: utc)
                == [entry(0, 360, 50)]
        )
        // Nothing to keep is nil, so an empty list can't read as unchanged.
        #expect(ISFTestEvaluator.coveredEntries([], from: time(5), to: time(9), calendar: utc) == nil)
    }

    @Test(
        "Below the docs' 150 the test raises glucose first; at or above it goes straight to the dose"
    ) func startPhaseFromGlucose() {
        #expect(ISFTestEvaluator.startPhase(glucose: 110, target: 100) == .raising)
        #expect(ISFTestEvaluator.startPhase(glucose: 149, target: 100) == .raising)
        #expect(ISFTestEvaluator.startPhase(glucose: 150, target: 100) == .dosing)
        #expect(ISFTestEvaluator.startPhase(glucose: 212, target: 100) == .dosing)
    }

    @Test(
        "With a target at or above the docs' 150 there is nothing for tablets to aim for, so the test goes to the dose"
    ) func noRaiseWithHighTarget() {
        #expect(ISFTestEvaluator.canRaise(target: 100))
        #expect(ISFTestEvaluator.canRaise(target: 149))
        #expect(!ISFTestEvaluator.canRaise(target: 150))
        #expect(!ISFTestEvaluator.canRaise(target: 160))
        // Below 150, but the tablets would aim at or under the target.
        #expect(ISFTestEvaluator.startPhase(glucose: 110, target: 150) == .dosing)
        #expect(ISFTestEvaluator.startPhase(glucose: 149, target: 160) == .dosing)
    }

    @Test(
        "The dose can be worked out once there is one and glucose is level, or once glucose levels off after the tablets acted"
    ) func canDose() {
        func can(
            _ phase: ISFTestPhase,
            tablets: Bool = true,
            acted: Bool = true,
            _ direction: BloodGlucose.Direction?,
            recent: Bool = true,
            dose: Decimal? = nil,
            iobAllows: Bool = true,
            cob: Decimal? = 0
        ) -> Bool {
            ISFTestEvaluator.canDose(
                phase: phase,
                tabletsTaken: tablets,
                tabletsActed: acted,
                isLevel: ISFTestEvaluator.isLevel(direction: direction, hasRecentReading: recent),
                dose: dose,
                iobAllowsDose: iobAllows,
                carbsOnBoard: cob
            )
        }
        // Carbs on board, or carbs not read yet, hold the dose with everything else in place, on both paths.
        #expect(!can(.dosing, tablets: false, acted: false, .flat, dose: dec("2.24"), cob: 5))
        #expect(!can(.dosing, tablets: false, acted: false, .flat, dose: dec("2.24"), cob: nil))
        #expect(!can(.raising, .flat, cob: dec("0.5")))
        #expect(!can(.raising, .flat, cob: nil))
        #expect(ISFTestEvaluator.carbsAllowDose(0))
        #expect(!ISFTestEvaluator.carbsAllowDose(1))
        #expect(!ISFTestEvaluator.carbsAllowDose(nil))
        // Dosing: when the docs' formula gives a dose and the arrow is flat, on the way straight to the dose too.
        #expect(can(.dosing, tablets: false, acted: false, .flat, dose: dec("2.24")))
        #expect(!can(.dosing, tablets: false, acted: false, .singleUp, dose: dec("2.24")))
        #expect(!can(.dosing, tablets: false, acted: false, .fortyFiveDown, dose: dec("2.24")))
        #expect(!can(.dosing, .flat, dose: nil))
        // Insulin on board over the line for the dose shown holds it up.
        #expect(!can(.dosing, tablets: false, acted: false, .flat, dose: dec("2.24"), iobAllows: false))
        // Raising: not before the tablets.
        #expect(!can(.raising, tablets: false, .flat, dose: dec("2.24")))
        // After them, a flat arrow once they have acted, and not before.
        #expect(can(.raising, .flat))
        #expect(!can(.raising, acted: false, .flat))
        // Or no arrow from a CGM that is reading, so a CGM without arrows doesn't hold the test up.
        let noArrow: [BloodGlucose.Direction?] = [nil, BloodGlucose.Direction.none, .notComputable]
        for direction in noArrow {
            #expect(can(.raising, direction, recent: true))
            #expect(can(.dosing, direction, recent: true, dose: dec("2.24")))
            // A CGM that stopped reading gives no arrow either, and that isn't glucose leveling off.
            #expect(!can(.raising, direction, recent: false))
            #expect(!can(.dosing, direction, recent: false, dose: dec("2.24")))
            #expect(ISFTestEvaluator.isLevel(direction: direction, hasRecentReading: true))
            #expect(!ISFTestEvaluator.isLevel(direction: direction, hasRecentReading: false))
        }
        // Moving, including faster than the CGM's arrows go.
        let moving: [BloodGlucose.Direction] = [
            .rateOutOfRange, .tripleUp, .doubleUp, .singleUp, .fortyFiveUp, .fortyFiveDown, .singleDown, .doubleDown,
            .tripleDown
        ]
        for direction in moving {
            #expect(!can(.raising, direction, dose: dec("2.24")))
            #expect(!can(.dosing, direction, dose: dec("2.24")))
            #expect(!ISFTestEvaluator.isLevel(direction: direction, hasRecentReading: true))
        }
        #expect(ISFTestEvaluator.isLevel(direction: .flat, hasRecentReading: true))
        // Once the bolus is in, there is nothing left to dose.
        #expect(!can(.waiting, .flat, dose: dec("2.24")))
        #expect(!can(.finished, .flat, dose: dec("2.24")))
    }

    @Test(
        "A flat reading from before the tablets acted doesn't unlock the dose; a rise and then a level one does"
    ) func tabletsActed() {
        func reading(_ seconds: TimeInterval, _ glucose: Int) -> BasalTestReading {
            BasalTestReading(date: at(seconds), glucose: glucose)
        }
        let takenAt = at(600)
        func acted(_ readings: [BasalTestReading], glucoseAtTablets: Int? = 110) -> Bool {
            ISFTestEvaluator.tabletsActed(readings, tabletsTakenAt: takenAt, glucoseAtTablets: glucoseAtTablets)
        }
        let before = [reading(300, 110), reading(590, 110)]
        let rise = [reading(900, 118), reading(1200, 126), reading(1500, 128)]
        // Only readings from before the tablets, flat as they are: nothing has acted.
        #expect(!acted(before))
        // Three readings after them, no higher on average than where they were counted from.
        #expect(!acted(before + [reading(900, 110), reading(1200, 109), reading(1500, 111)]))
        // Fewer than the 3 the mean needs, however high.
        #expect(!acted(before + [reading(900, 118)]))
        #expect(!acted(before + [reading(900, 118), reading(1200, 126)]))
        // The mean of the newest 3 after them above it: the arrow on the newest then decides.
        #expect(acted(before + rise))
        #expect(acted(rise.reversed() + before))
        // One small blip doesn't move the mean above it (110, 110, 112 average 110).
        #expect(!acted(before + [reading(900, 110), reading(1200, 112), reading(1500, 110)]))
        // The newest 3: glucose that rose and came back down hasn't held the rise.
        #expect(!acted(before + rise + [reading(1800, 110), reading(2100, 108), reading(2400, 109)]))
        // A reading at the moment the tablets were saved isn't after them.
        #expect(!acted(before + [reading(600.4, 130), reading(600.6, 131), reading(900, 112)]))
        #expect(ISFTest.Config.meanReadings == 3)
        // Without the glucose saved when they were taken, the same mean at or before then (110).
        #expect(acted(before + rise, glucoseAtTablets: nil))
        #expect(!acted(rise, glucoseAtTablets: nil))

        // Through the screen's decision: the flat arrow from before them doesn't unlock the dose; after the rise it does.
        let flatBefore = ISFTestEvaluator.canDose(
            phase: .raising,
            tabletsTaken: true,
            tabletsActed: acted(before),
            isLevel: ISFTestEvaluator.isLevel(direction: .flat, hasRecentReading: true),
            dose: nil,
            iobAllowsDose: true,
            carbsOnBoard: 0
        )
        #expect(!flatBefore)
        let flatAfterRise = ISFTestEvaluator.canDose(
            phase: .raising,
            tabletsTaken: true,
            tabletsActed: acted(before + rise),
            isLevel: ISFTestEvaluator.isLevel(direction: .flat, hasRecentReading: true),
            dose: nil,
            iobAllowsDose: true,
            carbsOnBoard: 0
        )
        #expect(flatAfterRise)
    }

    @Test("Without a dose the screen can tell why: no recent reading, at or below target, or no settings") func noDoseReason() {
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: 50, carbsOnBoard: 0) == nil)
        #expect(ISFTestEvaluator.noDoseReason(glucose: nil, target: 100, isf: 50, carbsOnBoard: 0) == .noRecentReading)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 100, target: 100, isf: 50, carbsOnBoard: 0) == .atOrBelowTarget)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 90, target: 100, isf: 50, carbsOnBoard: 0) == .atOrBelowTarget)
        // Missing settings come first: waiting for a reading wouldn't help.
        #expect(ISFTestEvaluator.noDoseReason(glucose: nil, target: nil, isf: 50, carbsOnBoard: 0) == .noSettings)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: nil, carbsOnBoard: 0) == .noSettings)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: 0, carbsOnBoard: 0) == .noSettings)
        // There is a reason exactly when the docs' formula gives no dose.
        for glucose in 80 ... 130 {
            let dose = ISFTestEvaluator.dose(glucose: glucose, target: 105, isf: 45)
            #expect(
                (ISFTestEvaluator.noDoseReason(glucose: glucose, target: 105, isf: 45, carbsOnBoard: 0) == nil) ==
                    (dose != nil)
            )
        }
        // Carbs on board give no dose whatever glucose is: the docs test ISF "when fasting (no COB)". Only missing
        // settings come before them.
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: 50, carbsOnBoard: 1) == .carbsOnBoard)
        #expect(ISFTestEvaluator.noDoseReason(glucose: nil, target: 100, isf: 50, carbsOnBoard: dec("0.5")) == .carbsOnBoard)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 90, target: 100, isf: 50, carbsOnBoard: 12) == .carbsOnBoard)
        #expect(
            ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: 50, handling: .count, iob: 1, carbsOnBoard: 12)
                == .carbsOnBoard
        )
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: nil, isf: 50, carbsOnBoard: 12) == .noSettings)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: 50, carbsOnBoard: 0) == nil)
        // The same rule holds up Begin.
        #expect(ISFTestEvaluator.carbsOnBoardBlockBegin(dec("0.5")))
        #expect(ISFTestEvaluator.carbsOnBoardBlockBegin(20))
        #expect(!ISFTestEvaluator.carbsOnBoardBlockBegin(0))
        // Not read: Begin isn't held up, but the Dose step waits for a read that says none.
        #expect(!ISFTestEvaluator.carbsOnBoardBlockBegin(nil))
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: 100, isf: 50, carbsOnBoard: nil) == .carbsUnread)
        #expect(ISFTestEvaluator.noDoseReason(glucose: nil, target: 100, isf: 50, carbsOnBoard: nil) == .carbsUnread)
        #expect(ISFTestEvaluator.noDoseReason(glucose: 212, target: nil, isf: 50, carbsOnBoard: nil) == .noSettings)
        // Carbs on board give no dose to show, read or not.
        #expect(ISFTestEvaluator.testDose(glucose: 212, target: 100, isf: 50, handling: nil, iob: 0, carbsOnBoard: 5) == nil)
        #expect(ISFTestEvaluator.testDose(glucose: 212, target: 100, isf: 50, handling: nil, iob: 0, carbsOnBoard: nil) == nil)
        #expect(
            ISFTestEvaluator.testDose(glucose: 212, target: 100, isf: 50, handling: nil, iob: 0, carbsOnBoard: 0) == dec("2.24")
        )
        // Which reasons wait for a reading, with Open Treatments shown turned off, and which are dead ends.
        let waits: [ISFTestNoDose] = [.carbsUnread, .iobUnread, .noRecentReading]
        let deadEnds: [ISFTestNoDose] = [.atOrBelowTarget, .carbsOnBoard, .iobCoversDose, .noSettings]
        for reason in waits {
            #expect(reason.isWaiting)
        }
        for reason in deadEnds {
            #expect(!reason.isWaiting)
        }
    }

    @Test(
        "Carbs on board are the newest determination's from the last 12 minutes; none that recent is unread, not none"
    ) func carbsOnBoardRead() {
        func determination(_ seconds: TimeInterval, cob: Decimal?, iob: String? = "0") -> ISFTestDetermination {
            ISFTestDetermination(date: at(seconds), iob: iob.map(dec), cob: cob)
        }
        let now = at(3600)
        let maxAge = BasalTest.Config.endReadingMaxAge
        #expect(ISFTestEvaluator.recentCOB([determination(3000, cob: 12), determination(3300, cob: 0)], now: now) == 0)
        #expect(ISFTestEvaluator.recentCOB([determination(3300, cob: 12), determination(3500, cob: nil)], now: now) == 12)
        #expect(ISFTestEvaluator.recentCOB([determination(3600 - maxAge, cob: 4)], now: now) == 4)
        // Trio hasn't looped for longer than that: unread, so neither Begin's row nor the dose reads it as none.
        #expect(ISFTestEvaluator.recentCOB([determination(3600 - maxAge - 2, cob: 0)], now: now) == nil)
        #expect(ISFTestEvaluator.recentCOB([], now: now) == nil)

        // At the bolus: the newest at or before it, from the 12 minutes before it.
        let bolusAt = at(1200)
        #expect(ISFTestEvaluator.cobAtBolus([determination(900, cob: 0), determination(1199.5, cob: 3)], bolusAt: bolusAt) == 3)
        #expect(ISFTestEvaluator.cobAtBolus([determination(900, cob: 0), determination(1260, cob: 3)], bolusAt: bolusAt) == 0)
        #expect(ISFTestEvaluator.cobAtBolus([determination(1200 - maxAge - 2, cob: 0)], bolusAt: bolusAt) == nil)
    }

    @Test(
        "Before the bolus, a check that rests on there being no bolus waits for a tick where the boluses could be read"
    ) func unreadBolusesDeferNoBolus() {
        func deferred(_ check: ISFTestEvaluator.RunningCheck?, read: Bool) -> ISFTestEvaluator.RunningCheck? {
            ISFTestEvaluator.decidable(check, bolusesRead: read)
        }
        // Unread, no bolus can't be told from one not seen yet, nor a low before the dose from one after it.
        #expect(deferred(.noBolus, read: false) == nil)
        #expect(deferred(.lowBeforeDose(at: at(600)), read: false) == nil)
        // The others end the test whether or not the bolus came.
        #expect(deferred(.carbsLogged(at: at(600)), read: false) == .carbsLogged(at: at(600)))
        #expect(deferred(.extraBolus(at: at(600)), read: false) == .extraBolus(at: at(600)))
        #expect(deferred(.modeChanged, read: false) == .modeChanged)
        #expect(deferred(.carbsUnreadable(at: at(600)), read: false) == .carbsUnreadable(at: at(600)))
        #expect(deferred(.unexplainedSuspend(at: at(600)), read: false) == .unexplainedSuspend(at: at(600)))
        #expect(deferred(nil, read: false) == nil)
        // Read, every check stands.
        #expect(deferred(.noBolus, read: true) == .noBolus)
        #expect(deferred(.lowBeforeDose(at: at(600)), read: true) == .lowBeforeDose(at: at(600)))
    }

    @Test(
        "Counting insulin on board, the dose is the docs' bolus calculator without carbs or trend: correction less what's on board"
    ) func countedDose() {
        // (200 − 100) ÷ 50 = 2.00 U, less 1.09 U on board.
        #expect(ISFTestEvaluator.countedDose(glucose: 200, target: 100, isf: 50, iob: dec("1.09")) == dec("0.91"))
        #expect(
            ISFTestEvaluator
                .testDose(glucose: 200, target: 100, isf: 50, handling: .count, iob: dec("1.09"), carbsOnBoard: 0) == dec("0.91")
        )
        // Basal Trio held back adds to it.
        #expect(
            ISFTestEvaluator
                .testDose(glucose: 200, target: 100, isf: 50, handling: .count, iob: dec("-0.3"), carbsOnBoard: 0) == dec("2.3")
        )
        // Insulin on board is taken off as shown, to 2 decimals: 2.24 − 1.094 shown as 1.09 is 1.15.
        #expect(ISFTestEvaluator.unroundedCountedDose(glucose: 212, target: 100, isf: 50, iob: dec("1.094")) == dec("1.15"))
        // Waiting for it, or with no choice at Begin, the dose is the docs' correction, whatever is on board.
        for handling in [ISFTestIOBHandling.wait, nil] {
            #expect(
                ISFTestEvaluator
                    .testDose(glucose: 200, target: 100, isf: 50, handling: handling, iob: dec("1.09"), carbsOnBoard: 0) == 2
            )
            #expect(
                ISFTestEvaluator
                    .testDose(glucose: 200, target: 100, isf: 50, handling: handling, iob: nil, carbsOnBoard: 0) == 2
            )
            #expect(
                ISFTestEvaluator
                    .noDoseReason(glucose: 200, target: 100, isf: 50, handling: handling, iob: 3, carbsOnBoard: 0) == nil
            )
        }

        // Insulin on board at or above the correction leaves nothing to give, with its own reason.
        #expect(ISFTestEvaluator.countedDose(glucose: 200, target: 100, isf: 50, iob: 2) == nil)
        #expect(ISFTestEvaluator.countedDose(glucose: 200, target: 100, isf: 50, iob: dec("2.5")) == nil)
        #expect(ISFTestEvaluator.testDose(glucose: 200, target: 100, isf: 50, handling: .count, iob: 2, carbsOnBoard: 0) == nil)
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: 200, target: 100, isf: 50, handling: .count, iob: 2, carbsOnBoard: 0) == .iobCoversDose
        )
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: 200, target: 100, isf: 50, handling: .count, iob: dec("1.09"), carbsOnBoard: 0) == nil
        )
        // Counted but not read yet: no dose until Trio has it.
        #expect(ISFTestEvaluator.testDose(glucose: 200, target: 100, isf: 50, handling: .count, iob: nil, carbsOnBoard: 0) == nil)
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: 200, target: 100, isf: 50, handling: .count, iob: nil, carbsOnBoard: 0) == .iobUnread
        )
        // The reasons before it come first.
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: 90, target: 100, isf: 50, handling: .count, iob: nil, carbsOnBoard: 0) == .atOrBelowTarget
        )
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: nil, target: 100, isf: 50, handling: .count, iob: 2, carbsOnBoard: 0) == .noRecentReading
        )
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: 200, target: nil, isf: 50, handling: .count, iob: 2, carbsOnBoard: 0) == .noSettings
        )

        // A counted dose that shows as 0.00 U is none: (201 − 100) ÷ 45 ≈ 2.2444, less 2.24 on board, is 0.0044.
        #expect(ISFTestEvaluator.countedDose(glucose: 201, target: 100, isf: 45, iob: dec("2.24")) == nil)
        #expect(
            ISFTestEvaluator
                .testDose(glucose: 201, target: 100, isf: 45, handling: .count, iob: dec("2.24"), carbsOnBoard: 0) == nil
        )
        #expect(
            ISFTestEvaluator.noDoseReason(glucose: 201, target: 100, isf: 45, handling: .count, iob: dec("2.24"), carbsOnBoard: 0)
                == .iobCoversDose
        )
        // Nor is one under the pump's bolus increment, which the pump can't give: 0.04 U at 0.05, but 0.05 U is a dose.
        let increment = dec("0.05")
        #expect(ISFTestEvaluator.countedDose(glucose: 200, target: 100, isf: 50, iob: dec("1.96"), increment: increment) == nil)
        #expect(
            ISFTestEvaluator.noDoseReason(
                glucose: 200, target: 100, isf: 50, handling: .count, iob: dec("1.96"), increment: increment,
                carbsOnBoard: 0
            ) == .iobCoversDose
        )
        #expect(
            ISFTestEvaluator.countedDose(glucose: 200, target: 100, isf: 50, iob: dec("1.95"), increment: increment)
                == increment
        )
        #expect(
            ISFTestEvaluator.testDose(
                glucose: 200, target: 100, isf: 50, handling: .count, iob: dec("1.95"), increment: increment,
                carbsOnBoard: 0
            ) == increment
        )
        #expect(
            ISFTestEvaluator.noDoseReason(
                glucose: 200, target: 100, isf: 50, handling: .count, iob: dec("1.95"), increment: increment,
                carbsOnBoard: 0
            ) == nil
        )
        // Waiting for it, the increment doesn't apply: the docs' dose is shown as before.
        #expect(
            ISFTestEvaluator.testDose(
                glucose: 200,
                target: 100,
                isf: 50,
                handling: .wait,
                iob: dec("1.96"),
                increment: increment,
                carbsOnBoard: 0
            )
                == 2
        )

        // Trio's suggestion, and so the yellow note, follows the counted dose: about 0.73 U of the 0.91 U at 80%.
        let counted = ISFTestEvaluator.testDose(
            glucose: 200,
            target: 100,
            isf: 50,
            handling: .count,
            iob: dec("1.09"),
            carbsOnBoard: 0
        )
        #expect(counted.map { ISFTestEvaluator.suggestion(for: $0, percentage: dec("0.8")) } == dec("0.73"))
    }

    @Test(
        "Insulin on board for a counted dose is the newest determination's from the last 12 minutes, none if older"
    ) func recentIOBForTheDose() {
        func determination(_ seconds: TimeInterval, _ iob: String?) -> ISFTestDetermination {
            ISFTestDetermination(date: at(seconds), iob: iob.map(dec))
        }
        let now = at(3600)
        let maxAge = BasalTest.Config.endReadingMaxAge
        #expect(
            ISFTestEvaluator.recentIOB([determination(3000, "1.2"), determination(3300, "1.09")], now: now) == dec("1.09")
        )
        // Signed, and one with no amount is passed over.
        #expect(ISFTestEvaluator.recentIOB([determination(3300, "-0.3"), determination(3500, nil)], now: now) == dec("-0.3"))
        // Exactly 12 minutes old still counts; older, or none, is unread, so the Dose step waits.
        #expect(ISFTestEvaluator.recentIOB([determination(3600 - maxAge, "1.09")], now: now) == dec("1.09"))
        #expect(ISFTestEvaluator.recentIOB([determination(3600 - maxAge - 2, "1.09")], now: now) == nil)
        #expect(ISFTestEvaluator.recentIOB([], now: now) == nil)
        let stale = ISFTestEvaluator.recentIOB([determination(1800, "1.09")], now: now)
        #expect(stale == nil)
        #expect(
            ISFTestEvaluator
                .noDoseReason(glucose: 200, target: 100, isf: 50, handling: .count, iob: stale, carbsOnBoard: 0) == .iobUnread
        )
        #expect(
            ISFTestEvaluator
                .testDose(glucose: 200, target: 100, isf: 50, handling: .count, iob: stale, carbsOnBoard: 0) == nil
        )
    }

    @Test("Settling's minutes left are whole minutes from now, rounded down") func settleMinutesLeft() {
        let allowance = ISFTest.Config.settleAllowance
        // Right at Begin, the hour; a second later, a minute has started to run.
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: testStart) == 60)
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: at(1)) == 59)
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: at(0.5)) == 59)
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: at(60)) == 59)
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: at(61)) == 58)
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: at(allowance - 59)) == 0)
        #expect(ISFTestEvaluator.settleMinutesLeft(startedAt: testStart, now: at(allowance + 60)) == 0)
    }

    @Test("Trio's suggestion is the docs' dose times the Recommended Bolus Percentage, to 2 decimals") func trioSuggestion() {
        // R4's example: about 1.79 U of the docs' 2.24 U at 80%.
        #expect(ISFTestEvaluator.suggestion(for: dec("2.24"), percentage: dec("0.8")) == dec("1.79"))
        #expect(ISFTestEvaluator.suggestion(for: 3, percentage: 1) == 3)
        #expect(ISFTestEvaluator.suggestion(for: dec("2.22"), percentage: dec("0.7")) == dec("1.55"))
    }

    @Test("Only a bolus after the test's own spoils it") func extraBolusAfterTheTestBolus() {
        #expect(!ISFTestEvaluator.hasExtraBolus([bolus(1200)], after: at(1200)))
        #expect(ISFTestEvaluator.hasExtraBolus([bolus(1200), bolus(2400, "0.5")], after: at(1200)))
        #expect(!ISFTestEvaluator.hasExtraBolus([], after: at(1200)))
    }

    @Test("Each running check ends the test for its reason, with what to say about it") func endingForEachCheck() {
        func ending(_ check: ISFTestEvaluator.RunningCheck) -> ISFTestEvaluator.Ending {
            ISFTestEvaluator.ending(for: check, doseDeadline: doseDeadline)
        }
        #expect(
            ending(.lowBeforeDose(at: at(600)))
                == ISFTestEvaluator.Ending(
                    reason: .interrupted,
                    at: at(600),
                    note: "Trio suspended insulin for a low before the dose."
                )
        )
        #expect(ending(.low(at: at(3600))) == ISFTestEvaluator.Ending(reason: .low, at: at(3600), note: nil))
        #expect(
            ending(.carbsLogged(at: at(3600)))
                == ISFTestEvaluator.Ending(reason: .interrupted, at: at(3600), note: "Carbs were logged during the test.")
        )
        #expect(
            ending(.extraBolus(at: at(3600)))
                == ISFTestEvaluator.Ending(reason: .interrupted, at: at(3600), note: "Another bolus was given during the test.")
        )
        #expect(
            ending(.modeChanged)
                == ISFTestEvaluator.Ending(reason: .interrupted, at: nil, note: "The dosing mode changed during the test.")
        )
        // Ended at the stop, so nothing after it is read as part of the test.
        #expect(
            ending(.unexplainedSuspend(at: at(1800)))
                == ISFTestEvaluator.Ending(
                    reason: .interrupted,
                    at: at(1800),
                    note: "Basal was stopped during the test, and Trio can't tell whether it was for a low."
                )
        )
        #expect(
            ending(.carbsUnreadable(at: at(3600)))
                == ISFTestEvaluator.Ending(
                    reason: .interrupted,
                    at: at(3600),
                    note: "Trio couldn't read your carbs to check the test, so it brought your usual dosing back."
                )
        )
        // No bolus ends when the time for one ran out.
        #expect(ending(.noBolus) == ISFTestEvaluator.Ending(reason: .noBolus, at: doseDeadline, note: nil))
        #expect(ending(.completed) == ISFTestEvaluator.Ending(reason: .completed, at: nil, note: nil))
        #expect(ending(.completedUnchecked) == ISFTestEvaluator.Ending(reason: .unchecked, at: nil, note: nil))
        // Neither leaves anything to judge.
        #expect(
            ending(.bolusNotSeen)
                == ISFTestEvaluator.Ending(
                    reason: .interrupted,
                    at: nil,
                    note: "Trio didn't see the bolus in time, so it brought your usual dosing back. Nothing was saved."
                )
        )
        #expect(
            ending(.bolusCancelled)
                == ISFTestEvaluator.Ending(
                    reason: .interrupted,
                    at: nil,
                    note: "The bolus was cancelled before any insulin was delivered, so there's nothing to judge."
                )
        )
        // Ended at the pump's event, so nothing after it is read as part of the test.
        #expect(
            ending(.pumpInterrupted(at: at(2400)))
                == ISFTestEvaluator.Ending(
                    reason: .interrupted,
                    at: at(2400),
                    note: "Your pump was suspended, gave an alarm, or had its site or reservoir changed during the test."
                )
        )
    }

    @Test("The bolus is judged on the amount the pump history holds now, not the one first seen") func bolusAmountReread() {
        let bolusAt = at(1200)
        func row(_ seconds: TimeInterval, _ amount: String?) -> ISFTestBolusRecord {
            ISFTestBolusRecord(date: at(seconds), amount: amount.map(dec))
        }
        func amount(_ reread: [ISFTestBolusRecord]?, finishing: Bool = false) -> ISFTestBolusAmount {
            ISFTestEvaluator.bolusAmount(saved: 2, reread: reread, bolusAt: bolusAt, finishing: finishing)
        }
        // Delivered as programmed.
        #expect(amount([row(1200, "2")]) == .units(2))
        // Cut short (cancelled, an occlusion, a pod fault): the pump later reports what it delivered. The read takes any
        // bolus row, so one the pump history flagged as an SMB when it was finalized still counts.
        #expect(amount([row(1200.000_3, "1.15")]) == .units(dec("1.15")))
        #expect(amount([row(1200, "1.15")], finishing: true) == .units(dec("1.15")))
        // At 0 U: cancelled before any insulin went in.
        #expect(amount([row(1200, "0")]) == .cancelled)
        #expect(amount([row(1200, "0")], finishing: true) == .cancelled)
        // A row with no amount recorded keeps the amount first seen.
        #expect(amount([row(1200, nil)]) == .units(2))
        #expect(amount([row(1200, nil)], finishing: true) == .units(2))
        // No row at that moment (one 2 minutes later is another bolus): a running check keeps going on the saved
        // amount; the finish can't trust it.
        for reread in [[], [row(1320, "2")]] {
            #expect(amount(reread) == .units(2))
            #expect(amount(reread, finishing: true) == .unread)
        }
        // Unread, the same.
        #expect(amount(nil) == .units(2))
        #expect(amount(nil, finishing: true) == .unread)
        #expect(ISFTestEvaluator.bolusAmount(saved: nil, reread: nil, bolusAt: bolusAt, finishing: false) == .units(nil))
    }

    @Test("The archived record says what the result found") func summaryText() {
        #expect(ISFTestEvaluator.summary(for: .accurate, reason: .completed) == "Glucose fell by about your ISF")
        #expect(ISFTestEvaluator.summary(for: .tooHigh, reason: .completed) == "Glucose fell less than your ISF")
        // Too high because glucose rose says it rose, not that it fell less.
        #expect(
            ISFTestEvaluator.summary(for: .tooHigh, reason: .completed, startGlucose: 212, endGlucose: 230)
                == "Glucose rose instead of falling"
        )
        #expect(
            ISFTestEvaluator.summary(for: .tooHigh, reason: .completed, startGlucose: 212, endGlucose: 150)
                == "Glucose fell less than your ISF"
        )
        #expect(
            ISFTestEvaluator.summary(for: .tooHigh, reason: .completed, startGlucose: 212, endGlucose: 212)
                == "Glucose fell less than your ISF"
        )
        #expect(ISFTestEvaluator.summary(for: .tooLow, reason: .completed) == "Glucose fell more than your ISF")
        #expect(ISFTestEvaluator.summary(for: .tooLow, reason: .low) == "Trio suspended insulin for a low")
        #expect(ISFTestEvaluator.summary(for: .inconclusive, reason: .endedEarly) == "Ended too soon to tell")
        #expect(ISFTestEvaluator.summary(for: .invalid, reason: .interrupted) == "Test was interrupted")
    }

    // MARK: The screens' decisions

    @Test("The Check screen's path matches where Start goes, and says when the formula would give no dose") func startPath() {
        // Below 150 with a target under it, tablets come first.
        #expect(ISFTestEvaluator.startPath(glucose: 110, target: 100) == .raise)
        #expect(ISFTestEvaluator.startPath(glucose: 90, target: 100) == .raise)
        #expect(ISFTestEvaluator.startPath(glucose: 149, target: 100) == .raise)
        // At 150 or above, straight to the dose.
        #expect(ISFTestEvaluator.startPath(glucose: 150, target: 100) == .dose)
        #expect(ISFTestEvaluator.startPath(glucose: 212, target: 100) == .dose)
        // A target at or above 150: above it is the dose; at or below it there is nothing to dose or aim tablets at.
        #expect(ISFTestEvaluator.startPath(glucose: 170, target: 160) == .dose)
        #expect(ISFTestEvaluator.startPath(glucose: 160, target: 160) == .noDose)
        #expect(ISFTestEvaluator.startPath(glucose: 155, target: 160) == .noDose)
        #expect(ISFTestEvaluator.startPath(glucose: 120, target: 150) == .noDose)
        // Nothing to say without a reading or a target.
        #expect(ISFTestEvaluator.startPath(glucose: nil, target: 100) == nil)
        #expect(ISFTestEvaluator.startPath(glucose: 120, target: nil) == nil)
        // The path agrees with the phase Start picks and with the dose that phase would get.
        for target in [Decimal(90), 100, 149, 150, 180] {
            for glucose in 60 ... 260 {
                let path = ISFTestEvaluator.startPath(glucose: glucose, target: target)
                let phase = ISFTestEvaluator.startPhase(glucose: glucose, target: target)
                let dose = ISFTestEvaluator.dose(glucose: glucose, target: target, isf: 50)
                #expect((path == .raise) == (phase == .raising))
                #expect((path == .noDose) == (phase == .dosing && dose == nil))
            }
        }
    }

    @Test(
        "The Raise step says why there are no tablets: no reading, no carb ratio, or glucose already at the aim"
    ) func noTabletsReason() {
        #expect(ISFTestEvaluator.noTabletsReason(glucose: 110, carbRatio: 10) == nil)
        #expect(ISFTestEvaluator.noTabletsReason(glucose: nil, carbRatio: 10) == .noRecentReading)
        #expect(ISFTestEvaluator.noTabletsReason(glucose: 110, carbRatio: nil) == .noCarbRatio)
        #expect(ISFTestEvaluator.noTabletsReason(glucose: 110, carbRatio: 0) == .noCarbRatio)
        #expect(ISFTestEvaluator.noTabletsReason(glucose: 150, carbRatio: 10) == .atOrAboveAim)
        #expect(ISFTestEvaluator.noTabletsReason(glucose: 170, carbRatio: 10) == .atOrAboveAim)
        // A missing reading comes first: waiting for one is what helps.
        #expect(ISFTestEvaluator.noTabletsReason(glucose: nil, carbRatio: nil) == .noRecentReading)
        // There is a reason exactly when there are no tablets to count.
        for glucose in 100 ... 200 {
            let carbs = ISFTestEvaluator.tabletCarbs(glucose: glucose, carbRatio: 10, isf: 50)
            #expect((ISFTestEvaluator.noTabletsReason(glucose: glucose, carbRatio: 10) == nil) == (carbs > 0))
        }
    }

    @Test("The Check screen's basal row says what the newest basal test found") func basalGateText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * hour)
        let locale = Locale(identifier: "en_US")
        func text(_ gate: SettingsTestSchedule.BasalGate) -> String {
            ISFTestEvaluator.basalGateText(gate, now: now, locale: locale)
        }
        #expect(text(.ready(lastSteady: threeDaysAgo)) == "Last basal test was steady, 3 days ago")
        #expect(text(.noSteadyTest) == "No steady basal test yet")
        #expect(text(.changedSince(threeDaysAgo)) == "Basal rates changed since the last test")
        // A test that said to raise basal found it too low, and one that said to lower it found it too high.
        #expect(text(.lastWasNot(.increase, threeDaysAgo)) == "The last basal test said basal looks too low")
        #expect(text(.lastWasNot(.decrease, threeDaysAgo)) == "The last basal test said basal looks too high")
    }

    @Test(
        "The Check screen warns for a basal test that isn't steady, an ISF change and a low threshold, and for nothing else"
    ) func checkWarnings() {
        let threeDaysAgo = Date(timeIntervalSince1970: 1_800_000_000 - 3 * 24 * hour)
        let ready = SettingsTestSchedule.BasalGate.ready(lastSteady: threeDaysAgo)
        func warnings(_ gate: SettingsTestSchedule.BasalGate, crosses: Bool = false) -> Set<ISFTestWarning> {
            ISFTestEvaluator.warnings(basalGate: gate, crossesISFChange: crosses, lowThresholdAtTarget: false)
        }

        // All clear: nothing warns.
        #expect(warnings(ready).isEmpty)

        // Every gate but a ready one warns, as the hub's note shows for the same gates.
        let gates: [SettingsTestSchedule.BasalGate] = [
            .noSteadyTest,
            .changedSince(threeDaysAgo),
            .lastWasNot(.increase, threeDaysAgo),
            .lastWasNot(.decrease, threeDaysAgo)
        ]
        for gate in gates {
            #expect(warnings(gate) == [.basalNotSteady])
            #expect(SettingsTestKind.isfGateNote(for: gate) != nil)
        }
        #expect(SettingsTestKind.isfGateNote(for: ready) == nil)

        // Four hours over more than one ISF.
        #expect(warnings(ready, crosses: true) == [.isfChanges])
        // A low threshold at or above the target: Trio may suspend right after the dose.
        #expect(
            ISFTestEvaluator
                .warnings(basalGate: ready, crossesISFChange: false, lowThresholdAtTarget: true) == [.lowThreshold]
        )
        // Each on its own, so all three can show at once.
        #expect(ISFTestEvaluator.warnings(basalGate: .noSteadyTest, crossesISFChange: true, lowThresholdAtTarget: true) == [
            .basalNotSteady, .isfChanges, .lowThreshold
        ])
    }

    @Test(
        "The Check screen warns when Basal Testing's low threshold, the user's or 72 if higher, is at or above the target"
    ) func lowThresholdAtTarget() {
        #expect(Preferences.basalTestingThreshold == 72)
        #expect(!ISFTestEvaluator.lowThresholdAtTarget(threshold: 72, target: 100))
        #expect(!ISFTestEvaluator.lowThresholdAtTarget(threshold: 99, target: 100))
        #expect(ISFTestEvaluator.lowThresholdAtTarget(threshold: 100, target: 100))
        #expect(ISFTestEvaluator.lowThresholdAtTarget(threshold: 110, target: 100))
        #expect(!ISFTestEvaluator.lowThresholdAtTarget(threshold: 110, target: nil))
        // The threshold Basal Testing uses, from the user's.
        var preferences = Preferences()
        preferences.threshold_setting = 65
        #expect(preferences.clamped(for: .basalTesting).threshold_setting == 72)
        preferences.threshold_setting = 90
        #expect(preferences.clamped(for: .basalTesting).threshold_setting == 90)
    }

    @Test("The step bar skips Raise when no tablets were taken, and Dose and Wait when no bolus came") func skippedSteps() {
        func state(
            _ phase: ISFTestPhase,
            tablets: Decimal? = nil,
            bolus: Bool = false
        ) -> ISFTestState {
            var state = ISFTestState(phase: phase, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
            state.tabletBrand = GlucoseTabletBrand.dex4.rawValue
            state.tabletCarbs = tablets
            if bolus {
                state.bolusAt = at(20 * 60)
                state.bolusUnits = dec("2.24")
            }
            return state
        }
        func skipped(_ state: ISFTestState?) -> Set<ISFTest.Step> { ISFTestEvaluator.skippedSteps(of: state) }

        // Before Begin nothing has been passed, and settling passes over nothing.
        #expect(skipped(nil).isEmpty)
        #expect(skipped(state(.settling)).isEmpty)
        // On the Raise step it is the current step, taken or not.
        #expect(skipped(state(.raising)).isEmpty)
        #expect(skipped(state(.raising, tablets: 8)).isEmpty)

        // Straight to the dose, or Skip, Dose Now: Raise never happened.
        #expect(skipped(state(.dosing)) == [.raise])
        #expect(skipped(state(.waiting, bolus: true)) == [.raise])
        #expect(skipped(state(.finished, bolus: true)) == [.raise])
        // No grams is no tablets.
        #expect(skipped(state(.dosing, tablets: 0)) == [.raise])

        // Tablets taken, then the dose: everything happened.
        #expect(skipped(state(.dosing, tablets: 8)).isEmpty)
        #expect(skipped(state(.waiting, tablets: 8, bolus: true)).isEmpty)
        #expect(skipped(state(.finished, tablets: 8, bolus: true)).isEmpty)

        // Finished without a bolus: Dose and Wait never happened, and Raise only if the tablets did. Settle ran from
        // Begin, so it is never skipped, even for a test that ended while settling.
        #expect(skipped(state(.finished, tablets: 8)) == [.dose, .wait])
        #expect(skipped(state(.finished)) == [.raise, .dose, .wait])
        for phase in [ISFTestPhase.settling, .raising, .dosing, .waiting, .finished] {
            #expect(!skipped(state(phase)).contains(.settle))
            #expect(!skipped(state(phase, tablets: 8, bolus: true)).contains(.settle))
        }

        // The bar shows each skipped step as skipped, not as a green check, and the rest as before.
        typealias Bar = SettingsTestStepBar<ISFTest.Step>
        let interrupted = skipped(state(.finished))
        #expect(ISFTest.Step.allCases.map { Bar.status(of: $0, current: .result, skipped: interrupted) } == [
            .done, .done, .skipped, .skipped, .skipped, .current
        ])
        let dosing = skipped(state(.dosing))
        #expect(ISFTest.Step.allCases.map { Bar.status(of: $0, current: .dose, skipped: dosing) } == [
            .done, .done, .skipped, .current, .upcoming, .upcoming
        ])
        let settling = skipped(state(.settling))
        #expect(ISFTest.Step.allCases.map { Bar.status(of: $0, current: .settle, skipped: settling) } == [
            .done, .current, .upcoming, .upcoming, .upcoming, .upcoming
        ])
    }

    @Test("A formula result follows ≈ when showing it rounds it, or when glucose shows in mmol/L") func approximateResult() {
        #expect(!ISFTestEvaluator.isApproximate(dec("2.24"), fractionDigits: 2, units: .mgdL))
        #expect(!ISFTestEvaluator.isApproximate(8, fractionDigits: 1, units: .mgdL))
        #expect(ISFTestEvaluator.isApproximate(Decimal(100) / 45, fractionDigits: 2, units: .mgdL))
        #expect(ISFTestEvaluator.isApproximate(dec("3.75"), fractionDigits: 1, units: .mgdL))
        // In mmol/L the inputs are rounded for display, so even an exact mg/dL result is shown as about.
        #expect(ISFTestEvaluator.isApproximate(dec("2.24"), fractionDigits: 2, units: .mmolL))
    }

    @Test("The unrounded dose is what the shown dose was rounded from") func unroundedDose() {
        #expect(ISFTestEvaluator.unroundedDose(glucose: 212, target: 100, isf: 50) == dec("2.24"))
        #expect(ISFTestEvaluator.unroundedDose(glucose: 200, target: 100, isf: 45) == Decimal(100) / 45)
        #expect(ISFTestEvaluator.unroundedDose(glucose: 100, target: 100, isf: 50) == nil)
        #expect(ISFTestEvaluator.unroundedDose(glucose: 212, target: 100, isf: 0) == nil)
    }

    @Test("The note compares Trio's suggestion with the docs' dose by the Recommended Bolus Percentage") func suggestionComparison() {
        #expect(ISFTestEvaluator.suggestionComparison(percent: 80) == .less)
        #expect(ISFTestEvaluator.suggestionComparison(percent: 99) == .less)
        #expect(ISFTestEvaluator.suggestionComparison(percent: 100) == .same)
        #expect(ISFTestEvaluator.suggestionComparison(percent: 101) == .more)
        #expect(ISFTestEvaluator.suggestionComparison(percent: 120) == .more)
    }

    // MARK: Finishing once normal dosing is back

    @Test("Only a finish not already decided reads the suspend history again") func rereadsHistory() {
        #expect(ISFTestEvaluator.rereadsHistory(.completed))
        #expect(ISFTestEvaluator.rereadsHistory(.endedEarly))
        #expect(ISFTestEvaluator.rereadsHistory(.unchecked))
        #expect(!ISFTestEvaluator.rereadsHistory(.low))
        #expect(!ISFTestEvaluator.rereadsHistory(.interrupted))
        #expect(!ISFTestEvaluator.rereadsHistory(.noBolus))
    }

    @Test(
        "A suspend found once normal dosing is back ends the test as the running check would have: before the bolus interrupted, after it a low"
    ) func finishingAfterRestore() {
        let end = at(4 * hour)
        let bolusAt = at(20 * 60)
        func finishing(
            _ reason: ISFTestEndReason,
            _ suspend: BasalTestEvaluator.SuspendReading,
            bolusAt: Date? = bolusAt
        ) -> ISFTestEvaluator.Ending {
            ISFTestEvaluator.finishing(reason: reason, at: end, suspend: suspend, bolusAt: bolusAt, doseDeadline: doseDeadline)
        }
        func ending(_ check: ISFTestEvaluator.RunningCheck) -> ISFTestEvaluator.Ending {
            ISFTestEvaluator.ending(for: check, doseDeadline: doseDeadline)
        }

        for reason in [ISFTestEndReason.completed, .endedEarly, .unchecked] {
            // Trio's suspend after the bolus: a low, judged up to the suspend.
            let low = finishing(reason, .suspended(at: at(2 * hour)))
            #expect(low == ISFTestEvaluator.Ending(reason: .low, at: at(2 * hour), note: nil))
            // At the bolus counts as after it, as the running check splits them.
            #expect(finishing(reason, .suspended(at: bolusAt)).reason == .low)
            // Before it, or with no bolus at all, there was nothing to judge.
            let early = finishing(reason, .suspended(at: at(10 * 60)))
            #expect(early == ending(.lowBeforeDose(at: at(10 * 60))))
            #expect(early.reason == .interrupted)
            #expect(early.at == at(10 * 60))
            #expect(finishing(reason, .suspended(at: at(10 * 60)), bolusAt: nil) == early)
            // Basal stopped without Trio asking interrupts the test at the stop.
            let stopped = finishing(reason, .unexplained(at: at(3 * hour)))
            #expect(stopped == ending(.unexplainedSuspend(at: at(3 * hour))))
            #expect(stopped.reason == .interrupted)
            #expect(stopped.at == at(3 * hour))
            // A history still unreadable changes nothing.
            #expect(finishing(reason, .unreadable) == ISFTestEvaluator.Ending(reason: reason, at: end, note: nil))
        }

        // With nothing in the history, an unchecked end of the 4 hours completed; the others stay as they were.
        #expect(finishing(.unchecked, .none) == ISFTestEvaluator.Ending(reason: .completed, at: end, note: nil))
        #expect(finishing(.completed, .none) == ISFTestEvaluator.Ending(reason: .completed, at: end, note: nil))
        #expect(finishing(.endedEarly, .none) == ISFTestEvaluator.Ending(reason: .endedEarly, at: end, note: nil))
        // Without a bolus there were no 4 hours to complete.
        #expect(
            finishing(.unchecked, .none, bolusAt: nil) == ISFTestEvaluator.Ending(reason: .unchecked, at: end, note: nil)
        )

        // A low, an interruption or no bolus is already decided, whatever the history says now.
        for reason in [ISFTestEndReason.low, .interrupted, .noBolus] {
            #expect(
                finishing(reason, .suspended(at: at(2 * hour))) == ISFTestEvaluator.Ending(reason: reason, at: end, note: nil)
            )
            #expect(
                finishing(reason, .unexplained(at: at(2 * hour))) == ISFTestEvaluator.Ending(reason: reason, at: end, note: nil)
            )
        }
    }

    // MARK: The result

    /// A finished test as `finish` saves it: by default the docs' Bill example, 2.24 U 20 minutes after Start from 212
    /// mg/dL with an ISF of 50, ended `elapsedHours` after the bolus (after Start without one).
    private func finished(
        start: Int? = 212,
        end: Int? = 100,
        units: Decimal? = Decimal(string: "2.24"),
        elapsedHours: Double = 4,
        reason: ISFTestEndReason = .completed,
        bolus: Bool = true,
        interference: String? = nil,
        interferenceUnread: Bool? = false,
        target: Decimal = 100,
        left: Decimal? = 0
    ) -> ISFTestState {
        var state = ISFTestState(phase: .finished, startedAt: testStart, previousMode: .closed, isf: 50, target: target)
        let anchor = bolus ? at(20 * 60) : testStart
        if bolus {
            state.bolusAt = anchor
            state.bolusUnits = units
            // Read when a test that ran its 4 hours finishes: by default none left on board.
            if reason == .completed { state.iobAtEnd = left }
        }
        state.startGlucose = start
        state.endGlucose = end
        state.endedAt = anchor.addingTimeInterval(elapsedHours * hour)
        state.endReason = reason
        state.interference = interference
        state.interferenceUnread = interferenceUnread
        state.outcome = ISFTestEvaluator.evaluate(
            startGlucose: start,
            endGlucose: end,
            units: ISFTestEvaluator.judgedUnits(of: state),
            elapsed: elapsedHours * hour,
            reason: reason,
            interference: interference,
            interferenceUnread: interferenceUnread ?? false,
            iobUnread: ISFTestEvaluator.iobUnread(of: state),
            isf: 50,
            target: target,
            givenUnits: ISFTestEvaluator.givenUnits(of: state)
        ).outcome
        return state
    }

    @Test("A finished test's result is worked out again from what it saved, timed from the bolus") func evaluationOfSaved() {
        let accurate = ISFTestEvaluator.evaluation(of: finished())
        #expect(accurate == evaluate(end: 100))
        #expect(accurate?.outcome == .accurate)
        #expect(accurate?.dropPerUnit == 50)
        #expect(accurate?.share == 0)
        #expect(ISFTestEvaluator.evaluation(of: finished(end: 130)) == evaluate(end: 130))
        #expect(ISFTestEvaluator.evaluation(of: finished(end: 70)) == evaluate(end: 70))

        // The 4 hours run from the bolus, not from Start: 4 hours after Start is 20 minutes short of them.
        let short = finished(elapsedHours: 4 - 20.0 / 60)
        #expect(short.endedAt == testStart.addingTimeInterval(4 * hour))
        #expect(ISFTestEvaluator.evaluation(of: short)?.outcome == .inconclusive)

        // A low, an interruption and no bolus come back as `finish` judged them.
        #expect(ISFTestEvaluator.evaluation(of: finished(end: 60, elapsedHours: 2, reason: .low))?.outcome == .tooLow)
        let noBolus = finished(start: nil, end: nil, elapsedHours: 1.5, reason: .noBolus, bolus: false)
        #expect(ISFTestEvaluator.evaluation(of: noBolus)?.outcome == .invalid)
        // A state saved before `interferenceUnread` was kept reads as everything read.
        #expect(ISFTestEvaluator.evaluation(of: finished(interferenceUnread: nil))?.outcome == .accurate)

        // Not finished yet, there is nothing to work out.
        var waiting = finished()
        waiting.endedAt = nil
        waiting.endReason = nil
        #expect(ISFTestEvaluator.evaluation(of: waiting) == nil)
    }

    @Test(
        "Only whole readings inside one docs step of the expected end are accurate; with none there, there is no band"
    ) func accurateEndBand() {
        let bill = ISFTestEvaluator.accurateEnds(startGlucose: 212, units: dec("2.24"), isf: 50)
        #expect(bill == 95 ... 105)
        // 0.4 U × 50 = 20 mg/dL, one step of which is 1: only the expected end itself, 130, is inside.
        #expect(ISFTestEvaluator.accurateEnds(startGlucose: 150, units: dec("0.4"), isf: 50) == 130 ... 130)
        // 0.11 U × 50 = 5.5 mg/dL, so glucose should end at 144.5, and one step is 0.275: no whole reading is that close.
        // Even the nearest reading, 145, is one the verdict calls a change.
        #expect(ISFTestEvaluator.accurateEnds(startGlucose: 150, units: dec("0.11"), isf: 50) == nil)
        let nearest = evaluate(start: 150, end: 145, units: dec("0.11"))
        #expect(nearest.outcome != .accurate)
        // No dose, no drop.
        #expect(ISFTestEvaluator.accurateEnds(startGlucose: 150, units: 0, isf: 50) == nil)

        // Small doses, where one step of the drop is around a reading or less: the band holds exactly the accurate ends.
        for hundredths in 1 ... 60 {
            let units = Decimal(hundredths) / 100
            let band = ISFTestEvaluator.accurateEnds(startGlucose: 150, units: units, isf: 50)
            for end in 115 ... 155 {
                let verdict = evaluate(start: 150, end: end, units: units).outcome
                #expect(
                    (band?.contains(end) ?? false) == (verdict == .accurate),
                    "\(units) U, end \(end): \(verdict), band \(String(describing: band))"
                )
            }
        }
    }

    @Test(
        "The chart's band shows only for a result judged on the drop, and never shades a reading the verdict calls a change"
    ) func resultChartBand() {
        // Accurate, too high or too low by the drop: where glucose would end if the ISF were less than a step either way.
        #expect(ISFTestEvaluator.resultBand(of: finished(end: 100)) == 95 ... 105)
        #expect(ISFTestEvaluator.resultBand(of: finished(end: 130)) == 95 ... 105)
        #expect(ISFTestEvaluator.resultBand(of: finished(end: 70)) == 95 ... 105)

        // A low isn't judged on the drop, and a test with no verdict has nothing to compare it with.
        #expect(ISFTestEvaluator.resultBand(of: finished(end: 60, elapsedHours: 2, reason: .low)) == nil)
        #expect(ISFTestEvaluator.resultBand(of: finished(elapsedHours: 2, reason: .endedEarly)) == nil)
        #expect(ISFTestEvaluator.resultBand(of: finished(interferenceUnread: true)) == nil)
        #expect(ISFTestEvaluator.resultBand(of: finished(interference: "Carbs were logged during the test.")) == nil)
        #expect(ISFTestEvaluator.resultBand(of: finished(reason: .unchecked)) == nil)
        #expect(ISFTestEvaluator.resultBand(of: finished(units: nil)) == nil)
        #expect(ISFTestEvaluator.resultBand(of: finished(end: nil)) == nil)

        // A dose too small for any reading to lie within a step: no band, and no verdict either.
        let tiny = finished(start: 150, end: 145, units: dec("0.11"))
        #expect(tiny.outcome == .inconclusive)
        #expect(ISFTestEvaluator.resultBand(of: tiny) == nil)
    }

    @Test("A result with no verdict says why, in the order the evaluator decides it") func noVerdictReasons() {
        func why(_ test: ISFTestState) -> ISFTestNoVerdict? { ISFTestEvaluator.noVerdict(for: test) }
        let note = "Carbs were logged during the test."

        // No bolus ended the test, whatever else was found.
        let noBolus = finished(start: nil, end: nil, elapsedHours: 1.5, reason: .noBolus, bolus: false)
        #expect(why(noBolus) == .noBolus)
        var noBolusWithCarbs = noBolus
        noBolusWithCarbs.interference = note
        #expect(why(noBolusWithCarbs) == .noBolus)
        // Something spoiled it, with or without a note to say what.
        #expect(why(finished(elapsedHours: 2, reason: .interrupted, interference: note)) == .interrupted)
        #expect(why(finished(elapsedHours: 2, reason: .interrupted)) == .interrupted)
        #expect(why(finished(interference: note)) == .interrupted)
        // A record that couldn't be read comes before the rest, a low among them.
        #expect(why(finished(interferenceUnread: true)) == .historyUnread)
        #expect(why(finished(end: 60, elapsedHours: 2, reason: .low, interferenceUnread: true)) == .historyUnread)
        // A low is a verdict.
        #expect(why(finished(end: 60, elapsedHours: 2, reason: .low)) == nil)
        #expect(why(finished(reason: .unchecked)) == .lowUnchecked)
        #expect(why(finished(elapsedHours: 2, reason: .endedEarly)) == .tooSoon)
        #expect(why(finished(elapsedHours: 4 - 1.0 / 60)) == .tooSoon)
        #expect(why(finished(end: nil)) == .noReadings)
        #expect(why(finished(start: nil)) == .noReadings)
        #expect(why(finished(units: nil)) == .noAmount)
        #expect(why(finished(end: 100)) == nil)
        #expect(why(finished(end: 130)) == nil)
        #expect(why(finished(end: 70)) == nil)

        var waiting = finished()
        waiting.endedAt = nil
        waiting.endReason = nil
        #expect(why(waiting) == nil)

        // There is a reason exactly when there is no verdict, and an interruption exactly when the result is unusable.
        let reasons: [ISFTestEndReason] = [.completed, .endedEarly, .low, .interrupted, .unchecked, .noBolus]
        let inputs: [(start: Int?, end: Int?, units: Decimal?)] = [
            (212, 100, dec("2.24")), (212, 130, dec("2.24")), (nil, 100, dec("2.24")), (212, nil, dec("2.24")), (212, 100, nil)
        ]
        let unusable: [ISFTestNoVerdict?] = [.noBolus, .interrupted]
        for reason in reasons {
            for elapsed in [2.0, 4.0] {
                for unread in [false, true] {
                    for input in inputs {
                        let test = finished(
                            start: input.start,
                            end: input.end,
                            units: input.units,
                            elapsedHours: elapsed,
                            reason: reason,
                            interferenceUnread: unread
                        )
                        let label = "\(reason), \(elapsed) h, unread \(unread), \(input)"
                        #expect((why(test) == nil) == (test.outcome?.isConclusive == true), "\(label)")
                        #expect(unusable.contains(why(test)) == (test.outcome == .invalid), "\(label)")
                    }
                }
            }
        }
    }

    @Test(
        "Tablets show as a count of the brand saved, or as grams when they aren't a whole number of it"
    ) func tabletsTakenBeforeTheDose() {
        #expect(ISFTestEvaluator.takenTablets(carbs: 12, brand: "dex4") == ISFTestTablets(count: 3, grams: 12))
        #expect(ISFTestEvaluator.takenTablets(carbs: 4, brand: "reliOn") == ISFTestTablets(count: 1, grams: 4))
        // TruePlus tablets are 3.75 g, as the Raise step adds them up.
        let three = Decimal(3) * GlucoseTabletBrand.trueplus.carbsPerTablet
        #expect(ISFTestEvaluator.takenTablets(carbs: three, brand: "trueplus") == ISFTestTablets(count: 3, grams: dec("11.25")))
        #expect(ISFTestEvaluator.takenTablets(carbs: dec("7.5"), brand: "trueplus")?.count == 2)
        // Tablets of another brand taken first leave grams that aren't a whole number of the last brand.
        #expect(
            ISFTestEvaluator
                .takenTablets(carbs: dec("19.5"), brand: "dex4") == ISFTestTablets(count: nil, grams: dec("19.5"))
        )
        #expect(ISFTestEvaluator.takenTablets(carbs: 12, brand: nil) == ISFTestTablets(count: nil, grams: 12))
        #expect(ISFTestEvaluator.takenTablets(carbs: 12, brand: "glucoseTabs") == ISFTestTablets(count: nil, grams: 12))
        // None taken.
        #expect(ISFTestEvaluator.takenTablets(carbs: nil, brand: "dex4") == nil)
        #expect(ISFTestEvaluator.takenTablets(carbs: 0, brand: "dex4") == nil)
    }

    @Test(
        "The working and the band show only when working the result out again gives the saved verdict"
    ) func workingOnlyForTheSavedVerdict() {
        #expect(ISFTestEvaluator.matchingEvaluation(of: finished()) == ISFTestEvaluator.evaluation(of: finished()))
        #expect(ISFTestEvaluator.matchingEvaluation(of: finished(end: 130))?.outcome == .tooHigh)

        // A verdict saved under other rules: the headline says too high, the readings now say accurate.
        var saved = finished(units: dec("1.79"), target: 100)
        saved.endGlucose = 122
        saved.outcome = .tooHigh
        #expect(ISFTestEvaluator.evaluation(of: saved)?.outcome == .accurate)
        #expect(ISFTestEvaluator.matchingEvaluation(of: saved) == nil)
        #expect(ISFTestEvaluator.resultBand(of: saved) == nil)
        #expect(ISFTestEvaluator.expectedEndAwayFromTarget(of: saved) == nil)
    }

    @Test("The band is shaded over the last 30 minutes before the 4 hours from the bolus are up") func bandShadingTimes() {
        let plannedEnd = at(20 * 60).addingTimeInterval(ISFTest.Config.docsWait)
        #expect(ISFTest.Config.expectedEndShading == 30 * 60)
        #expect(ISFTestEvaluator.resultBandTimes(of: finished()) == plannedEnd.addingTimeInterval(-30 * 60) ... plannedEnd)
        // The planned end, even for a test that ended sooner.
        #expect(ISFTestEvaluator.resultBandTimes(of: finished(elapsedHours: 2, reason: .endedEarly))?.upperBound == plannedEnd)
        // Without a bolus there are no 4 hours.
        let noBolus = finished(start: nil, end: nil, elapsedHours: 1.5, reason: .noBolus, bolus: false)
        #expect(ISFTestEvaluator.resultBandTimes(of: noBolus) == nil)
    }

    @Test(
        "Where an accurate ISF would have ended is said when it isn't at the target, so the docs' target line doesn't read against the verdict"
    ) func expectedEndNote() {
        func expected(_ test: ISFTestState) -> Decimal? { ISFTestEvaluator.expectedEndAwayFromTarget(of: test) }

        // The docs' dose aims at the target: 2.24 U × 50 from 212 ends at 100.
        #expect(expected(finished()) == nil)
        // 1.79 U, Trio's 80% of it: an accurate ISF ends near 122.5, above the 100 target, and the verdict is accurate.
        let smaller = finished(end: 122, units: dec("1.79"))
        #expect(smaller.outcome == .accurate)
        #expect(expected(smaller) == dec("122.5"))
        // Too high or too low say it too.
        #expect(expected(finished(end: 140, units: dec("1.79"))) == dec("122.5"))
        #expect(expected(finished(end: 100, units: dec("1.79"))) == dec("122.5"))
        // A larger dose ends below the target.
        #expect(expected(finished(end: 90, units: dec("2.44"))) == 90)
        // Within the band's half-width (one step of the drop) of the target, it isn't said: 2.30 U ends at 97, 3 from
        // the target, and one step of the 115 mg/dL drop is 5.75.
        #expect(expected(finished(end: 97, units: dec("2.3"))) == nil)
        // At exactly the half-width it isn't said, just past it it is: 2 U × 50 from 200 ends at 100, one step is 5.
        #expect(expected(finished(start: 200, end: 100, units: 2, target: 95)) == nil)
        #expect(expected(finished(start: 200, end: 100, units: 2, target: dec("94.9"))) == 100)

        // Only for a result judged on the drop per unit.
        #expect(expected(finished(end: 60, units: dec("1.79"), elapsedHours: 2, reason: .low)) == nil)
        #expect(expected(finished(end: 122, units: dec("1.79"), elapsedHours: 2, reason: .endedEarly)) == nil)
        #expect(expected(finished(end: 122, units: dec("1.79"), interferenceUnread: true)) == nil)
        #expect(expected(finished(end: nil, units: dec("1.79"))) == nil)
    }

    @Test("The drop per unit reads like the ISF beside it, with a minus sign only for a rise that shows") func perUnitDisplay() throws {
        let us = Locale(identifier: "en_US")
        func text(_ value: Decimal, _ units: GlucoseUnits = .mgdL) -> String {
            ISFTestEvaluator.perUnitText(value, units: units, locale: us)
        }
        #expect(text(50) == "50")
        #expect(text(Decimal(107) / dec("2.24")) == "47.8")
        // Glucose rose: 212 to 222 on 2.24 U is -4.46 mg/dL per unit.
        let rose = try #require(evaluate(end: 222).dropPerUnit)
        #expect(text(rose) == "-4.5")
        // A rise too small to show has no sign.
        #expect(text(dec("-0.04")) == "0")
        // In mmol/L a drop of exactly the ISF reads as the ISF does.
        #expect(text(50, .mmolL) == Decimal(50).formattedISF(for: .mmolL, locale: us))
        #expect(text(50, .mmolL) == "2.8")
        #expect(text(-10, .mmolL) == "-0.6")
        #expect(text(dec("-0.5"), .mmolL) == "0.0")
    }

    @Test(
        "The difference is a whole percent rounded toward zero, so an accurate result never shows the docs' 5%"
    ) func percentDisplay() {
        #expect(ISFTestEvaluator.percentText(0) == "0%")
        #expect(ISFTestEvaluator.percentText(dec("0.12")) == "+12%")
        #expect(ISFTestEvaluator.percentText(dec("0.0499")) == "+4%")
        // A minus sign, as the formulas write it, not a hyphen.
        #expect(ISFTestEvaluator.percentText(dec("-0.0499")) == "\u{2212}4%")
        #expect(ISFTestEvaluator.percentText(dec("-0.05")) == "\u{2212}5%")
        #expect(ISFTestEvaluator.percentText(dec("-0.004")) == "0%")

        // Every end reading for the docs' example and a dose that leaves fractions: an accurate one shows under 5%, a
        // change 5% or more.
        for units in [dec("2.24"), dec("1.79"), dec("2.01")] {
            for end in 60 ... 160 {
                let evaluation = evaluate(end: end, units: units)
                guard let share = evaluation.share else { continue }
                let shown = abs(BasalTestEvaluator.wholePercent(share))
                if evaluation.outcome == .accurate {
                    #expect(shown < 5, "\(units) U, end \(end): \(ISFTestEvaluator.percentText(share))")
                    #expect(!["+5%", "\u{2212}5%"].contains(ISFTestEvaluator.percentText(share)))
                } else {
                    #expect(shown >= 5, "\(units) U, end \(end): \(ISFTestEvaluator.percentText(share))")
                }
            }
        }
    }

    // MARK: Saved dates against the history

    /// The pump history keeps microseconds; the saved state keeps whole milliseconds, rounded either way. The simulator
    /// run's bolus: 0.796319 s past the second, saved as .796.
    private let bolusMoment: TimeInterval = 1220.796319
    private func savedBelow(_ seconds: TimeInterval) -> Date { at((seconds * 1000).rounded(.down) / 1000) }
    private func savedAbove(_ seconds: TimeInterval) -> Date { at((seconds * 1000).rounded(.up) / 1000) }

    @Test("A saved date and a history timestamp under a second apart are the same moment") func savedDateTolerance() {
        let event = at(bolusMoment)
        for saved in [savedBelow(bolusMoment), savedAbove(bolusMoment), event] {
            #expect(ISFTestEvaluator.isSameMoment(event, saved))
            #expect(!ISFTestEvaluator.isAfter(event, saved))
            #expect(!ISFTestEvaluator.isBefore(event, saved))
        }
        // A second apart is two moments: two manual boluses can't be that close.
        #expect(ISFTestEvaluator.isAfter(at(bolusMoment + 1), event))
        #expect(ISFTestEvaluator.isBefore(at(bolusMoment - 1), event))
        #expect(!ISFTestEvaluator.isSameMoment(at(bolusMoment + 1), event))
        #expect(ISFTest.Config.savedDateTolerance == 1)
    }

    @Test(
        "The test's own bolus is never another one, whichever way its saved time was rounded"
    ) func ownBolusAfterSavingIsNotExtra() throws {
        let own = ISFTestBolus(date: at(bolusMoment), units: dec("1.6"))
        #expect(!ISFTestEvaluator.hasExtraBolus([own], after: savedBelow(bolusMoment)))
        #expect(!ISFTestEvaluator.hasExtraBolus([own], after: savedAbove(bolusMoment)))
        // Through the state file, as a reopened screen reads it.
        var state = ISFTestState(phase: .waiting, startedAt: testStart, previousMode: .closed, isf: 50, target: 110)
        state.bolusAt = own.date
        let reloaded = try JSONCoding.decoder.decode(ISFTestState.self, from: JSONCoding.encoder.encode(state))
        let savedBolusAt = try #require(reloaded.bolusAt)
        #expect(!ISFTestEvaluator.hasExtraBolus([own], after: savedBolusAt))
        // A real second bolus 2 minutes later is another one.
        let second = ISFTestBolus(date: at(bolusMoment + 120), units: dec("0.5"))
        #expect(ISFTestEvaluator.hasExtraBolus([own, second], after: savedBelow(bolusMoment)))
        #expect(ISFTestEvaluator.hasExtraBolus([own, second], after: savedBolusAt))
    }

    @Test(
        "The test bolus flagged as an SMB isn't Trio dosing; another SMB-flagged bolus still is"
    ) func smbFlaggedTestBolusIsNotTrioDosing() {
        let own = BasalTestSMB(date: at(bolusMoment), units: dec("1.6"))
        let later = BasalTestSMB(date: at(bolusMoment + 300), units: dec("0.5"))
        for saved in [savedBelow(bolusMoment), savedAbove(bolusMoment)] {
            #expect(ISFTestEvaluator.smbs([own, later], besidesTestBolusAt: saved) == [later])
            #expect(ISFTestEvaluator.smbs([own], besidesTestBolusAt: saved).isEmpty)
        }
        // Before the bolus there is no test bolus to leave out.
        #expect(ISFTestEvaluator.smbs([own, later], besidesTestBolusAt: nil) == [own, later])
    }

    @Test(
        "A bolus a fraction of a millisecond past the saved deadline is still the test bolus; none before Start is"
    ) func testBolusWindowEdges() {
        // Nobody gives the test bolus before tapping Start, so the start edge is exact.
        let beforeStart = ISFTestBolus(date: at(0.000_4), units: 2)
        #expect(ISFTestEvaluator.testBolus([beforeStart], since: at(0.001), deadline: doseDeadline) == nil)
        #expect(ISFTestEvaluator.testBolus([beforeStart], since: at(0.000_4), deadline: doseDeadline) == beforeStart)
        // The saved deadline rounded down before a bolus at that moment.
        let deadlineMoment = ISFTest.Config.doseAllowance + 0.000_6
        let atDeadline = ISFTestBolus(date: at(deadlineMoment), units: 2)
        #expect(ISFTestEvaluator.testBolus([atDeadline], since: testStart, deadline: savedBelow(deadlineMoment)) == atDeadline)
        // A second or more outside isn't.
        #expect(ISFTestEvaluator.testBolus([bolus(-1)], since: testStart, deadline: doseDeadline) == nil)
        #expect(
            ISFTestEvaluator
                .testBolus([bolus(ISFTest.Config.doseAllowance + 1)], since: testStart, deadline: doseDeadline) == nil
        )
    }

    @Test("A low at the moment of the saved bolus is a low after it, not one before the dose") func lowAtTheSavedBolus() {
        // The zero temp a fraction of a millisecond before the bolus time as saved, which was rounded up.
        let saved = savedAbove(bolusMoment)
        let suspendedAt = at(bolusMoment - 0.000_2)
        func waiting(_ suspend: BasalTestEvaluator.SuspendReading, ended: SettingsTestEnd? = nil) -> ISFTestEvaluator
            .RunningCheck?
        {
            ISFTestEvaluator.runningCheck(
                phase: .waiting,
                sessionID: testSession,
                serviceEnd: ended,
                suspend: suspend,
                now: at(3600),
                doseDeadline: doseDeadline,
                bolusAt: saved,
                plannedEnd: saved.addingTimeInterval(ISFTest.Config.docsWait),
                mode: ended == nil ? .basalTesting : .closed
            )
        }
        #expect(waiting(.suspended(at: suspendedAt)) == .low(at: suspendedAt))
        let record = SettingsTestEnd(sessionID: testSession, cause: .low, date: suspendedAt)
        #expect(waiting(.none, ended: record) == .low(at: suspendedAt))
        // A second or more before it is still a low before the dose.
        #expect(waiting(.suspended(at: at(bolusMoment - 1))) == .lowBeforeDose(at: at(bolusMoment - 1)))
        // The same split when the finish reads the history again.
        let finished = ISFTestEvaluator.finishing(
            reason: .completed,
            at: at(4 * hour),
            suspend: .suspended(at: suspendedAt),
            bolusAt: saved,
            doseDeadline: doseDeadline
        )
        #expect(finished.reason == .low)
        // A second or more before it, the finish too says there was nothing to judge.
        let early = ISFTestEvaluator.finishing(
            reason: .completed,
            at: at(4 * hour),
            suspend: .suspended(at: at(bolusMoment - 1)),
            bolusAt: saved,
            doseDeadline: doseDeadline
        )
        #expect(early.reason == .interrupted)
        #expect(early.at == at(bolusMoment - 1))
    }

    @Test(
        "End Test at or after the 4 hours finishes as the running check would have: completed, or unchecked unread"
    ) func endTestAfterThePlannedEnd() {
        let bolusAt = at(20 * 60)
        let plannedEnd = bolusAt.addingTimeInterval(ISFTest.Config.docsWait)
        func finishing(at end: Date, _ suspend: BasalTestEvaluator.SuspendReading) -> ISFTestEvaluator.Ending {
            ISFTestEvaluator.finishing(
                reason: .endedEarly,
                at: end,
                suspend: suspend,
                bolusAt: bolusAt,
                doseDeadline: doseDeadline
            )
        }
        // `finish` caps the end at the planned end, so End Test after it ends there.
        #expect(finishing(at: plannedEnd, .none) == ISFTestEvaluator.Ending(reason: .completed, at: plannedEnd, note: nil))
        #expect(
            finishing(at: plannedEnd, .unreadable) == ISFTestEvaluator.Ending(reason: .unchecked, at: plannedEnd, note: nil)
        )
        // A low in the 4 hours is still a low.
        #expect(finishing(at: plannedEnd, .suspended(at: at(2 * hour))).reason == .low)
        // Before the 4 hours are up it is ended early.
        let before = plannedEnd.addingTimeInterval(-60)
        #expect(finishing(at: before, .none) == ISFTestEvaluator.Ending(reason: .endedEarly, at: before, note: nil))
        // Without a bolus there were no 4 hours to finish.
        #expect(
            ISFTestEvaluator.finishing(
                reason: .endedEarly,
                at: plannedEnd,
                suspend: .none,
                bolusAt: nil,
                doseDeadline: doseDeadline
            )
            .reason == .endedEarly
        )
    }

    @Test(
        "A service record dated a few milliseconds past the saved dose deadline still decides"
    ) func serviceEndJustPastTheSavedDeadline() {
        // The service dates its records from its own session, which began a few milliseconds after the saved Start.
        let deadline = ISFTest.Config.doseAllowance
        #expect(
            check(.dosing, ended: serviceEnd(.carbsLogged, after: deadline + 0.004), now: deadline + 60, mode: .closed)
                == .carbsLogged(at: at(deadline + 0.004))
        )
        // A second or more past it doesn't.
        #expect(
            check(.dosing, ended: serviceEnd(.carbsLogged, after: deadline + 1), now: deadline + 60, mode: .closed)
                == .noBolus
        )
    }

    @Test("A reading at the moment of the saved bolus counts as at it and as since it") func readingsAroundTheSavedBolus() {
        let atBolus = BasalTestReading(date: at(bolusMoment + 0.000_1), glucose: 210)
        let before = BasalTestReading(date: at(bolusMoment - 300), glucose: 212)
        let after = BasalTestReading(date: at(bolusMoment + 300), glucose: 205)
        let readings = [before, atBolus, after]
        for saved in [savedBelow(bolusMoment), savedAbove(bolusMoment)] {
            #expect(ISFTestEvaluator.readings(readings, atOrBefore: saved) == [before, atBolus])
            #expect(ISFTestEvaluator.readings(readings, since: saved) == [atBolus, after])
        }
    }

    // MARK: Insulin on board and settling

    @Test(
        "The line is the docs' 5% of the expected dose, and insulin on board is judged by its size either way"
    ) func iobDecision() {
        // The mockup's numbers: a 2.00 U dose, so a 0.10 U line.
        #expect(ISFTestEvaluator.iobLine(expectedDose: 2) == dec("0.1"))
        func decide(_ iob: String, dose: Decimal? = 2) -> ISFTestIOBDecision? {
            ISFTestEvaluator.iobDecision(iob: dec(iob), expectedDose: dose)
        }
        #expect(decide("0") == .fine)
        // Exactly the line is fine, just over it is a choice.
        #expect(decide("0.1") == .fine)
        #expect(decide("0.11") == .choice(line: dec("0.1")))
        #expect(decide("0.3") == .choice(line: dec("0.1")))
        // Exactly the whole dose is still a choice, just over it holds Begin up.
        #expect(decide("2") == .choice(line: dec("0.1")))
        #expect(decide("2.01") == .blocked)
        // Negative insulin on board, basal Trio held back, counts by its size.
        #expect(decide("-0.1") == .fine)
        #expect(decide("-0.11") == .choice(line: dec("0.1")))
        #expect(decide("-2.01") == .blocked)
        // Without an expected dose there is nothing to decide.
        #expect(decide("5", dose: nil) == nil)
        #expect(decide("5", dose: 0) == nil)
        // Nor before Trio has read insulin on board: the row says so, and Begin isn't held up.
        #expect(ISFTestEvaluator.iobDecision(iob: nil, expectedDose: 2) == nil)

        // The line is rounded to 2 decimals, as shown, before it is compared: 5% of 2.24 U is 0.112, shown 0.11.
        #expect(ISFTestEvaluator.iobLine(expectedDose: dec("2.24")) == dec("0.11"))
        #expect(ISFTestEvaluator.iobLine(expectedDose: dec("2.5")) == dec("0.13"))
        #expect(ISFTestEvaluator.iobDecision(iob: dec("0.11"), expectedDose: dec("2.24")) == .fine)
        // Insulin on board is rounded as shown too: 0.114 U shows as 0.11, on the line; 0.115 shows as 0.12, over it.
        #expect(ISFTestEvaluator.iobDecision(iob: dec("0.114"), expectedDose: dec("2.24")) == .fine)
        #expect(ISFTestEvaluator.iobDecision(iob: dec("0.115"), expectedDose: dec("2.24")) == .choice(line: dec("0.11")))
        #expect(ISFTestEvaluator.iobDecision(iob: dec("-0.114"), expectedDose: dec("2.24")) == .fine)
        #expect(ISFTestEvaluator.iobDecision(iob: dec("-0.115"), expectedDose: dec("2.24")) == .choice(line: dec("0.11")))
        // And against the whole dose: 2.244 U shows as 2.24, the dose itself; 2.245 shows as 2.25, over it.
        #expect(ISFTestEvaluator.iobDecision(iob: dec("2.244"), expectedDose: dec("2.24")) == .choice(line: dec("0.11")))
        #expect(ISFTestEvaluator.iobDecision(iob: dec("2.245"), expectedDose: dec("2.24")) == .blocked)
        #expect(ISFTestEvaluator.shownSize(of: dec("-0.115")) == dec("0.12"))
        // What is shown is what is compared: units show rounded half up, as the comparisons round them.
        let english = Locale(identifier: "en_US")
        #expect(ISFTestEvaluator.shownUnits(dec("2.244"), locale: english) == "2.24")
        #expect(ISFTestEvaluator.shownUnits(dec("2.245"), locale: english) == "2.25")
        #expect(ISFTestEvaluator.shownUnits(dec("0.125"), locale: english) == "0.13")
        #expect(ISFTestEvaluator.shownUnits(dec("0.115"), locale: english) == "0.12")
        #expect(ISFTestEvaluator.shownUnits(2, locale: english) == "2.00")

        // Begin keeps the choice only when there was one to make.
        #expect(ISFTestEvaluator.iobHandling(for: .choice(line: dec("0.1")), chosen: .count) == .count)
        #expect(ISFTestEvaluator.iobHandling(for: .choice(line: dec("0.1")), chosen: .wait) == .wait)
        #expect(ISFTestEvaluator.iobHandling(for: .fine, chosen: .count) == nil)
        #expect(ISFTestEvaluator.iobHandling(for: .blocked, chosen: .wait) == nil)
        #expect(ISFTestEvaluator.iobHandling(for: nil, chosen: .count) == nil)
    }

    @Test(
        "The expected dose is the docs' dose now on the way to the dose, and at the docs' 150 on the way through tablets"
    ) func expectedDose() {
        func expected(_ path: ISFTestStartPath?, _ glucose: Int?, target: Decimal? = 100, isf: Decimal? = 50) -> Decimal? {
            ISFTestEvaluator.expectedDose(startPath: path, glucose: glucose, target: target, isf: isf)
        }
        // Straight to the dose: (212 − 100) ÷ 50.
        #expect(expected(.dose, 212) == dec("2.24"))
        // Through tablets, at the aim, not the glucose now: (150 − 100) ÷ 50, so the line is 0.05 U.
        #expect(expected(.raise, 120) == 1)
        #expect(expected(.raise, nil) == 1)
        #expect(ISFTestEvaluator.iobDecision(iob: dec("0.06"), expectedDose: expected(.raise, 120)) == .choice(line: dec("0.05")))
        #expect(ISFTestEvaluator.iobDecision(iob: dec("0.05"), expectedDose: expected(.raise, 120)) == .fine)
        // Nothing to expect: no dose on the path, no reading, or no settings.
        #expect(expected(.noDose, 140, target: 150) == nil)
        #expect(expected(nil, 212) == nil)
        #expect(expected(.dose, nil) == nil)
        #expect(expected(.dose, 212, target: nil) == nil)
        #expect(expected(.dose, 212, isf: nil) == nil)
        #expect(expected(.dose, 212, isf: 0) == nil)
    }

    /// Settling from `testStart`, with determinations `determinations` seconds after it, and CGM readings `readings`
    /// seconds after it: by default every 5 minutes from Begin, so 3 have come after a loop at 330 s by 20 minutes in.
    private func settle(
        _ determinations: [TimeInterval],
        readings: [TimeInterval] = Array(stride(from: 0, through: 1200, by: 300)),
        tempBasalRunning: Bool? = false,
        iob: String? = "0",
        line: String? = "0.1",
        handling: ISFTestIOBHandling? = nil,
        now: TimeInterval = 1200
    ) -> ISFTestSettling {
        ISFTestEvaluator.settling(
            startedAt: testStart,
            determinations: determinations.map(at),
            readings: readings.map(at),
            tempBasalRunning: tempBasalRunning,
            iob: iob.map(dec),
            line: line.map(dec),
            handling: handling,
            now: at(now)
        )
    }

    @Test("Settling waits for a determination at least a minute after Begin") func settlingWaitsForTheLoop() {
        #expect(ISFTest.Config.settleLoopMargin == 60)
        #expect(ISFTest.Config.settleAllowance == hour)
        // None yet, or only a loop from before Begin and one already running at it.
        #expect(settle([]) == .waiting(loopedAt: nil, waitsForIOB: false))
        #expect(settle([-120, 30]) == .waiting(loopedAt: nil, waitsForIOB: false))
        // The next loop ran in Basal Testing.
        #expect(settle([30, 330]) == .settled)
        #expect(settle([30, 330], iob: "0.3", handling: .wait) == .waiting(loopedAt: at(330), waitsForIOB: true))
        // The first one from a minute after Begin on, in any order.
        #expect(ISFTestEvaluator.firstLoopInTestMode([at(330), at(30), at(60)], startedAt: testStart) == at(60))
        #expect(ISFTestEvaluator.firstLoopInTestMode([at(30), at(59)], startedAt: testStart) == nil)
    }

    @Test(
        "Waiting for it, settling ends once insulin on board is at or under the line; counting it, insulin on board doesn't hold it"
    ) func settlingWaitsForIOB() {
        #expect(settle([330], iob: "0.3", handling: .wait) == .waiting(loopedAt: at(330), waitsForIOB: true))
        #expect(settle([330], iob: "0.1", handling: .wait) == .settled)
        // Either way.
        #expect(settle([330], iob: "-0.3", handling: .wait) == .waiting(loopedAt: at(330), waitsForIOB: true))
        #expect(settle([330], iob: "-0.1", handling: .wait) == .settled)
        // Before the loop it waits for both.
        #expect(settle([], iob: "0.3", handling: .wait) == .waiting(loopedAt: nil, waitsForIOB: true))
        // Counting it, only the loop.
        #expect(settle([330], iob: "0.3", handling: .count) == .settled)
        #expect(settle([], iob: "0.3", handling: .count) == .waiting(loopedAt: nil, waitsForIOB: false))
        // No choice at Begin, then an SMB given as the test began pushed it over the line: it waits, as for Wait for It.
        #expect(settle([330], iob: "0.3", handling: nil) == .waiting(loopedAt: at(330), waitsForIOB: true))
        #expect(settle([330], iob: "0.05", handling: nil) == .settled)
        // Without a line (no expected dose at Begin), only the loop.
        #expect(settle([330], iob: "3", line: nil, handling: nil) == .settled)
    }

    @Test("After an hour with insulin on board still over the line, settling asks, and never ends on its own") func settlingTimeUp() {
        let allowance = ISFTest.Config.settleAllowance
        #expect(settle([330], iob: "0.3", handling: .wait, now: allowance - 1) == .waiting(
            loopedAt: at(330),
            waitsForIOB: true
        ))
        #expect(settle([330], iob: "0.3", handling: .wait, now: allowance) == .timeUp(loopedAt: at(330)))
        #expect(settle([330], iob: "0.3", handling: .wait, now: 3 * allowance) == .timeUp(loopedAt: at(330)))
        #expect(settle([330], iob: "0.3", handling: nil, now: allowance) == .timeUp(loopedAt: at(330)))
        // Come under the line by then, or counted with Count It and Go On, it ends.
        #expect(settle([330], iob: "0.1", handling: .wait, now: allowance + 60) == .settled)
        #expect(settle([330], iob: "0.3", handling: .count, now: allowance + 60) == .settled)
        // With no loop in Basal Testing by then, counting can't help, so it only says so, whatever insulin on board is.
        #expect(settle([], now: allowance - 1) == .waiting(loopedAt: nil, waitsForIOB: false))
        #expect(settle([], handling: .wait, now: allowance) == .noLoop)
        #expect(settle([], iob: "0.3", handling: .wait, now: 2 * allowance) == .noLoop)
        #expect(settle([30], iob: "0.3", handling: .count, now: allowance) == .noLoop)

        #expect(ISFTestEvaluator.settleTimeLeft(startedAt: testStart, now: at(600)) == allowance - 600)
        #expect(ISFTestEvaluator.settleTimeLeft(startedAt: testStart, now: at(allowance + 5)) == 0)
    }

    @Test("A bolus given while the test settles is shown, and is never the test bolus") func settlingBolusIsNeverTheTestBolus() throws {
        var state = ISFTestState(phase: .dosing, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        state.settledAt = at(600)
        let windowStart = try #require(state.bolusWindowStart)
        #expect(windowStart == at(600))
        // An SMB Trio decided before Begin, given 5 seconds after it, and the user's bolus after settling.
        let stray = bolus(5, "0.3")
        let user = bolus(1200)
        #expect(ISFTestEvaluator.testBolus([stray, user], since: windowStart, deadline: state.doseDeadline) == user)
        #expect(ISFTestEvaluator.testBolus([stray], since: windowStart, deadline: state.doseDeadline) == nil)
        // Flagged as an SMB, it is the one Trio gave; one given by hand isn't flagged.
        let strayRow = ISFTestSettlingBolus(date: stray.date, units: stray.units, isSMB: true)
        let smbs = [BasalTestSMB(date: stray.date, units: stray.units)]
        #expect(
            ISFTestEvaluator.settlingBoluses([user, stray], smbs: smbs, startedAt: testStart, settledAt: at(600)) == [strayRow]
        )
        #expect(ISFTestEvaluator.settlingBoluses([stray], smbs: [], startedAt: testStart, settledAt: at(600)) == [
            ISFTestSettlingBolus(date: stray.date, units: stray.units, isSMB: false)
        ])
        // SMBs that couldn't be read call none an SMB.
        #expect(ISFTestEvaluator.settlingBoluses([stray], smbs: nil, startedAt: testStart, settledAt: at(600)).map(\.isSMB) == [
            false
        ])
        // The stray SMB came before the test bolus, so it isn't another bolus after it.
        #expect(!ISFTestEvaluator.hasExtraBolus([stray, user], after: user.date))

        // Each bolus is on one side of the end of settling: just before it is settling's, at it the test's.
        let justBefore = bolus(599.5)
        let atEnd = bolus(600)
        #expect(
            ISFTestEvaluator.settlingBoluses([atEnd, justBefore], smbs: [], startedAt: testStart, settledAt: at(600))
                .map(\.date) == [justBefore.date]
        )
        #expect(ISFTestEvaluator.testBolus([justBefore, atEnd], since: windowStart, deadline: state.doseDeadline) == atEnd)

        // While settling, every bolus since Begin and none from before it.
        #expect(
            ISFTestEvaluator.settlingBoluses([user, bolus(-60), stray], smbs: smbs, startedAt: testStart, settledAt: nil)
                .map(\.date) == [stray.date, user.date]
        )
    }

    @Test(
        "The 90 minutes for the bolus run from the end of settling, and a test still settling waits as long as the service"
    ) func doseDeadlineFromSettling() {
        var state = ISFTestState(phase: .settling, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        #expect(state.bolusWindowStart == nil)
        #expect(state.noBolusDeadline == at(ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance))

        state.phase = .dosing
        state.settledAt = at(1200)
        #expect(state.bolusWindowStart == at(1200))
        #expect(state.doseDeadline == at(1200 + ISFTest.Config.doseAllowance))
        #expect(state.noBolusDeadline == state.doseDeadline)

        // A test begun before settling was kept carries on from Start.
        let old = ISFTestState(phase: .raising, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        #expect(old.bolusWindowStart == testStart)
        #expect(old.doseDeadline == doseDeadline)
        #expect(old.noBolusDeadline == doseDeadline)

        // Settling moves on to the step the glucose as it ends leads to, whatever Begin planned: glucose can move in
        // up to an hour of settling.
        state.plannedPhase = .dosing
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: 140) == .raising)
        state.plannedPhase = .raising
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: 160) == .dosing)
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: 150) == .dosing)
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: 149) == .raising)
        // A target of the docs' 150 or more leaves nothing for tablets to aim past, so it goes to the dose.
        var highTarget = state
        highTarget.target = 150
        #expect(ISFTestEvaluator.phaseAfterSettling(highTarget, glucose: 140) == .dosing)
        // Without a recent reading, the step Begin planned, the dose without one.
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: nil) == .raising)
        state.plannedPhase = .dosing
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: nil) == .dosing)
        state.plannedPhase = nil
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: nil) == .dosing)
        // Settling has no dose to work out.
        #expect(!ISFTestEvaluator.canDose(
            phase: .settling,
            tabletsTaken: true,
            tabletsActed: true,
            isLevel: ISFTestEvaluator.isLevel(direction: .flat, hasRecentReading: true),
            dose: 2,
            iobAllowsDose: true,
            carbsOnBoard: 0
        ))
    }

    @Test(
        "Settling, the test ends for what ends it before the bolus, and for no bolus only when the service's time is up"
    ) func settlingRunningCheck() {
        let limit = ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance
        let state = ISFTestState(phase: .settling, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        func settlingCheck(
            ended: SettingsTestEnd? = nil,
            suspend: BasalTestEvaluator.SuspendReading = .none,
            now: TimeInterval,
            mode: DosingMode = .basalTesting
        ) -> ISFTestEvaluator.RunningCheck? {
            ISFTestEvaluator.runningCheck(
                phase: .settling,
                sessionID: testSession,
                serviceEnd: ended,
                suspend: suspend,
                now: at(now),
                doseDeadline: state.noBolusDeadline,
                bolusAt: nil,
                plannedEnd: nil,
                mode: mode
            )
        }
        #expect(settlingCheck(now: 600) == nil)
        // Past the 90 minutes a settled test would have: still settling, still running.
        #expect(settlingCheck(now: ISFTest.Config.doseAllowance + 60) == nil)
        #expect(settlingCheck(now: limit - 1) == nil)
        // Time up while settling is settling not finishing, not a bolus that didn't come.
        #expect(settlingCheck(now: limit) == .settlingTimedOut)
        // The service's own end for no bolus, dated at the same time, is the same.
        #expect(
            settlingCheck(ended: serviceEnd(.noBolus, after: limit), now: limit + 30, mode: .closed) == .settlingTimedOut
        )
        // It ends at the service's time, with its own note, which the Result shows instead of the 90 minutes' line.
        let ending = ISFTestEvaluator.ending(for: .settlingTimedOut, doseDeadline: state.noBolusDeadline)
        #expect(ending == ISFTestEvaluator.Ending(
            reason: .interrupted,
            at: at(limit),
            note: "Settling didn't finish in time, so Trio brought your usual dosing back. Nothing was saved."
        ))
        #expect(ISFTestEvaluator.decidable(.settlingTimedOut, bolusesRead: false) == .settlingTimedOut)
        var timedOut = state
        timedOut.phase = .finished
        timedOut.endedAt = at(limit)
        timedOut.endReason = ending.reason
        timedOut.interference = ending.note
        #expect(ISFTestEvaluator.noVerdict(for: timedOut) == .interrupted)
        #expect(ISFTestEvaluator.evaluation(of: timedOut)?.outcome == .invalid)
        // A settled test still ends for no bolus at its dose deadline.
        #expect(check(.dosing, now: ISFTest.Config.doseAllowance) == .noBolus)
        // A low, carbs, or a mode changed while settling end it as before the dose.
        #expect(settlingCheck(ended: serviceEnd(.low, after: 600), now: 900, mode: .closed) == .lowBeforeDose(at: at(600)))
        #expect(
            settlingCheck(ended: serviceEnd(.carbsLogged, after: 600), now: 900, mode: .closed) == .carbsLogged(at: at(600))
        )
        #expect(settlingCheck(suspend: .suspended(at: at(300)), now: 600) == .lowBeforeDose(at: at(300)))
        #expect(settlingCheck(suspend: .unexplained(at: at(300)), now: 600) == .unexplainedSuspend(at: at(300)))
        #expect(settlingCheck(now: 600, mode: .closed) == .modeChanged)
    }

    @Test(
        "Insulin on board at the bolus is the newest determination's from the 12 minutes before it, not one at the bolus"
    ) func iobAtTheBolus() throws {
        func determination(_ seconds: TimeInterval, _ iob: String?) -> ISFTestDetermination {
            ISFTestDetermination(date: at(seconds), iob: iob.map(dec))
        }
        let determinations = [
            determination(1500, "2.4"),
            determination(300, "0.4"),
            determination(900, "0.3"),
            // Half a second before the saved bolus: the same moment, so it may hold the bolus.
            determination(1199.5, "2.5")
        ]
        #expect(ISFTestEvaluator.iobAtBolus(determinations, bolusAt: at(1200)) == dec("0.3"))
        // Signed, and one that holds no amount is passed over.
        #expect(
            ISFTestEvaluator.iobAtBolus([determination(800, "-0.2"), determination(900, nil)], bolusAt: at(1200)) == dec("-0.2")
        )
        #expect(ISFTestEvaluator.iobAtBolus([], bolusAt: at(1200)) == nil)
        #expect(ISFTestEvaluator.iobAtBolus([determination(1500, "2.4")], bolusAt: at(1200)) == nil)

        // At most 12 minutes before the bolus, Trio's own age for glucose that is too old; older is no reading of it.
        let maxAge = BasalTest.Config.endReadingMaxAge
        #expect(maxAge == 12 * 60)
        #expect(ISFTestEvaluator.iobAtBolus([determination(1200 - maxAge, "0.3")], bolusAt: at(1200)) == dec("0.3"))
        #expect(ISFTestEvaluator.iobAtBolus([determination(1200 - maxAge - 0.5, "0.3")], bolusAt: at(1200)) == dec("0.3"))
        #expect(ISFTestEvaluator.iobAtBolus([determination(1200 - maxAge - 2, "0.3")], bolusAt: at(1200)) == nil)
        // An old one doesn't stand in for a missing recent one.
        #expect(ISFTestEvaluator.iobAtBolus([determination(300, "0.4"), determination(900, nil)], bolusAt: at(1200)) == nil)
        // So a test that counts it has no verdict, with the unread-history wording.
        var stale = finished(units: 2)
        stale.iobHandling = .count
        stale.iobAtBolus = try ISFTestEvaluator.iobAtBolus([determination(300, "0.24")], bolusAt: #require(stale.bolusAt))
        #expect(stale.iobAtBolus == nil)
        #expect(ISFTestEvaluator.evaluation(of: stale)?.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: stale) == .historyUnread)
    }

    @Test(
        "The units judged are the bolus, plus the insulin on board at it when the test counts it, less what is left at 4 h"
    ) func judgedUnits() {
        var state = finished(units: 2)
        #expect(ISFTestEvaluator.givenUnits(of: state) == 2)
        #expect(ISFTestEvaluator.judgedUnits(of: state) == 2)
        state.iobAtBolus = dec("0.3")
        state.iobHandling = .wait
        #expect(ISFTestEvaluator.judgedUnits(of: state) == 2)
        state.iobHandling = .count
        #expect(ISFTestEvaluator.givenUnits(of: state) == dec("2.3"))
        #expect(ISFTestEvaluator.judgedUnits(of: state) == dec("2.3"))
        state.iobAtBolus = dec("-0.3")
        #expect(ISFTestEvaluator.judgedUnits(of: state) == dec("1.7"))
        #expect(!ISFTestEvaluator.iobUnread(of: state))
        // What Trio still had on board at the planned end hadn't acted, so it is left out, signed.
        state.iobAtEnd = dec("0.29")
        #expect(ISFTestEvaluator.judgedUnits(of: state) == dec("1.41"))
        state.iobAtEnd = dec("-0.05")
        #expect(ISFTestEvaluator.judgedUnits(of: state) == dec("1.75"))
        // Left at the end but not read: nothing to judge by, with the unread-history wording.
        state.iobAtEnd = nil
        #expect(ISFTestEvaluator.givenUnits(of: state) == dec("1.7"))
        #expect(ISFTestEvaluator.judgedUnits(of: state) == nil)
        #expect(ISFTestEvaluator.iobAtEndUnread(of: state))
        #expect(ISFTestEvaluator.iobUnread(of: state))
        state.iobAtEnd = 0
        // Counted but unread at the bolus: nothing to judge by.
        state.iobAtBolus = nil
        #expect(ISFTestEvaluator.givenUnits(of: state) == nil)
        #expect(ISFTestEvaluator.judgedUnits(of: state) == nil)
        #expect(ISFTestEvaluator.iobAtBolusUnread(of: state))
        #expect(ISFTestEvaluator.iobUnread(of: state))
        // Without a bolus there is nothing to have read.
        #expect(!ISFTestEvaluator.iobUnread(of: finished(start: nil, end: nil, reason: .noBolus, bolus: false)))
        // Only a test that ran its 4 hours reads what was left at the end: one ended sooner says nothing anyway.
        #expect(!ISFTestEvaluator.iobAtEndUnread(of: finished(elapsedHours: 2, reason: .endedEarly)))
        #expect(!ISFTestEvaluator.iobAtEndUnread(of: finished(end: 60, elapsedHours: 2, reason: .low)))
    }

    @Test(
        "Counting it, the result is judged per unit of the bolus and insulin on board; unread, there is no verdict"
    ) func countedResult() {
        // 2.00 U from 212 to 100 with an ISF of 50 is 56 per unit, too low by the bolus alone. With 0.24 U on board
        // counted it is 112 ÷ 2.24 = 50 per unit: accurate.
        func judged(_ handling: ISFTestIOBHandling?, iob: String?, end: Int? = 100, reason: ISFTestEndReason = .completed)
            -> ISFTestState
        {
            var state = finished(end: end, units: 2, elapsedHours: reason == .low ? 2 : 4, reason: reason)
            state.iobHandling = handling
            state.iobAtBolus = iob.map(dec)
            state.outcome = ISFTestEvaluator.evaluation(of: state)?.outcome
            return state
        }
        let counted = judged(.count, iob: "0.24")
        #expect(counted.outcome == .accurate)
        #expect(ISFTestEvaluator.evaluation(of: counted)?.dropPerUnit == 50)
        #expect(ISFTestEvaluator.resultBand(of: counted) == 95 ... 105)
        #expect(ISFTestEvaluator.expectedEndAwayFromTarget(of: counted) == nil)
        #expect(ISFTestEvaluator.noVerdict(for: counted) == nil)

        // Waiting for it, the same readings are judged on the bolus alone.
        let waited = judged(.wait, iob: "0.24")
        #expect(waited.outcome == .tooLow)
        #expect(ISFTestEvaluator.evaluation(of: waited)?.dropPerUnit == 56)
        #expect(ISFTestEvaluator.expectedEndAwayFromTarget(of: waited) == 112)

        // Counting it but unread: no verdict, with the words for a history that couldn't be read.
        let unread = judged(.count, iob: nil)
        #expect(unread.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: unread) == .historyUnread)
        #expect(ISFTestEvaluator.resultBand(of: unread) == nil)
        // A low is judged against the docs' dose, which needs the units given, so unread it has no verdict either.
        let unreadLow = judged(.count, iob: nil, end: 60, reason: .low)
        #expect(unreadLow.outcome == .inconclusive)
        #expect(ISFTestEvaluator.evaluation(of: unreadLow)?.direction == nil)
        #expect(ISFTestEvaluator.noVerdict(for: unreadLow) == .historyUnread)
        // Read, a low is still a low: 2.00 U plus 0.24 U on board is the docs' 2.24 U.
        #expect(judged(.count, iob: "0.24", end: 60, reason: .low).outcome == .tooLow)
    }

    @Test("Insulin on board Trio hasn't read never lets settling pass while it waits for it") func settlingWithUnreadIOB() {
        // Rounded as shown before it is compared with the line.
        #expect(!ISFTestEvaluator.waitsForIOB(iob: dec("0.104"), line: dec("0.1"), handling: .wait))
        #expect(ISFTestEvaluator.waitsForIOB(iob: dec("0.105"), line: dec("0.1"), handling: .wait))
        #expect(!ISFTestEvaluator.waitsForIOB(iob: dec("-0.104"), line: dec("0.1"), handling: nil))
        #expect(settle([330], iob: "0.104", handling: .wait) == .settled)
        #expect(settle([330], iob: "0.105", handling: .wait) == .waiting(loopedAt: at(330), waitsForIOB: true))

        #expect(ISFTestEvaluator.waitsForIOB(iob: nil, line: dec("0.1"), handling: .wait))
        #expect(ISFTestEvaluator.waitsForIOB(iob: nil, line: dec("0.1"), handling: nil))
        #expect(!ISFTestEvaluator.waitsForIOB(iob: nil, line: dec("0.1"), handling: .count))
        #expect(!ISFTestEvaluator.waitsForIOB(iob: nil, line: nil, handling: nil))
        #expect(settle([330], iob: nil, handling: .wait) == .waiting(loopedAt: at(330), waitsForIOB: true))
        #expect(settle([330], iob: nil, handling: nil) == .waiting(loopedAt: at(330), waitsForIOB: true))
        #expect(settle([330], iob: nil, handling: .count) == .settled)
        #expect(settle([330], iob: nil, line: nil) == .settled)
        // Still unread when the time is up: the question, as for insulin on board over the line.
        #expect(settle([330], iob: nil, handling: .wait, now: ISFTest.Config.settleAllowance) == .timeUp(loopedAt: at(330)))
    }

    @Test(
        "A tick settles only while the test's session runs in Basal Testing, before the latest a bolus window could close"
    ) func canSettle() {
        let limit = at(ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance)
        func can(active: UUID?, mode: DosingMode = .basalTesting, now: TimeInterval = 600, session: UUID? = nil) -> Bool {
            ISFTestEvaluator.canSettle(
                sessionID: session ?? testSession,
                activeSessionID: active,
                mode: mode,
                now: at(now),
                noBolusDeadline: limit
            )
        }
        #expect(can(active: testSession))
        // The service ended it, or another test's session runs.
        #expect(!can(active: nil))
        #expect(!can(active: UUID()))
        // The usual mode is back.
        #expect(!can(active: testSession, mode: .closed))
        // Out of time.
        #expect(!can(active: testSession, now: ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance))
        // A test with no session to match.
        #expect(!ISFTestEvaluator.canSettle(
            sessionID: nil,
            activeSessionID: nil,
            mode: .basalTesting,
            now: at(600),
            noBolusDeadline: limit
        ))
    }

    @Test(
        "Opened after the service ended a test still settling, it ends as settling not finishing, at the service's time"
    ) func reopenedAfterSettlingTimedOut() {
        let limit = ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance
        var state = ISFTestState(phase: .settling, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        state.sessionID = testSession
        state.iobLine = dec("0.1")
        let now = at(limit + 5 * 60)
        let lastEnd = serviceEnd(.noBolus, after: limit)

        // A determination 5 minutes after Begin and no insulin on board: settling would be done...
        let decision = ISFTestEvaluator.settling(
            startedAt: testStart,
            determinations: [at(5 * 60)],
            readings: [at(10 * 60), at(15 * 60), at(20 * 60)],
            tempBasalRunning: false,
            iob: 0,
            line: state.iobLine,
            handling: state.iobHandling,
            now: now
        )
        #expect(decision == .settled)
        // ...but the session is gone and the usual mode is back, so the tick doesn't settle it.
        #expect(!ISFTestEvaluator.canSettle(
            sessionID: state.sessionID,
            activeSessionID: nil,
            mode: .closed,
            now: now,
            noBolusDeadline: state.noBolusDeadline
        ))
        #expect(state.settledAt == nil)
        #expect(state.phase == .settling)

        // The running check, still settling, ends it with settling's note, at the service's time, not in the future.
        let check = ISFTestEvaluator.runningCheck(
            phase: state.phase,
            sessionID: state.sessionID,
            serviceEnd: lastEnd,
            suspend: .none,
            now: now,
            doseDeadline: state.noBolusDeadline,
            bolusAt: nil,
            plannedEnd: nil,
            mode: .closed
        )
        #expect(check == .settlingTimedOut)
        let ending = ISFTestEvaluator.ending(for: .settlingTimedOut, doseDeadline: state.noBolusDeadline)
        #expect(ending.reason == .interrupted)
        #expect(ending.note == "Settling didn't finish in time, so Trio brought your usual dosing back. Nothing was saved.")
        let endedAt = SettingsTestEndRule.endTime(endedAt: ending.at, limit: state.noBolusDeadline, now: now)
        #expect(endedAt == at(limit))
    }

    @Test("A finish never ends a test after its limit or in the future") func endTime() {
        #expect(SettingsTestEndRule.endTime(endedAt: at(600), limit: at(5400), now: at(1200)) == at(600))
        #expect(SettingsTestEndRule.endTime(endedAt: nil, limit: at(5400), now: at(1200)) == at(1200))
        #expect(SettingsTestEndRule.endTime(endedAt: nil, limit: at(5400), now: at(6000)) == at(5400))
        // An end a check dated in the future, or past the limit, is now, or the limit.
        #expect(SettingsTestEndRule.endTime(endedAt: at(9000), limit: at(12000), now: at(6000)) == at(6000))
        #expect(SettingsTestEndRule.endTime(endedAt: at(9000), limit: at(5400), now: at(10000)) == at(5400))
    }

    @Test(
        "The ISF schedule saved at Begin covers the latest the test can end: settling's bound, a bolus window and the 4 hours"
    ) func coveredAtBegin() {
        // Begin at 08:00 UTC. Settling can run to 10:30 (an hour, then the 90 minutes the service gives it), the bolus
        // can come 90 minutes after that, and the 4 hours end at 16:00.
        let begin = time(8)
        let entries = [entry(0, 480, 40), entry(480, 900, 45), entry(900, 960, 50), entry(960, 1440, 55)]
        #expect(ISFTestEvaluator.coveredAtBegin(entries, startedAt: begin, calendar: utc) == [
            entry(480, 900, 45), entry(900, 960, 50)
        ])
        let span = ISFTest.Config.settleAllowance + 2 * ISFTest.Config.doseAllowance + ISFTest.Config.docsWait
        #expect(span == 8 * hour)
        let state = ISFTestState(phase: .settling, startedAt: begin, previousMode: .closed, isf: 50, target: 100)
        #expect(
            state.noBolusDeadline.addingTimeInterval(ISFTest.Config.doseAllowance + ISFTest.Config.docsWait)
                == begin.addingTimeInterval(span)
        )
        #expect(
            ISFTestEvaluator.coveredAtBegin(entries, startedAt: begin, calendar: utc)
                == ISFTestEvaluator.coveredEntries(entries, from: begin, to: begin.addingTimeInterval(span), calendar: utc)
        )
    }

    @Test(
        "The Result words the units as the bolus, and in a test that counted it the insulin on board beside it, signed"
    ) func unitsText() {
        func text(_ handling: ISFTestIOBHandling?, iob: String?) -> String? {
            var state = finished(units: 2)
            state.iobHandling = handling
            state.iobAtBolus = iob.map(dec)
            return ISFTestEvaluator.unitsText(of: state) { $0.formatted(.number.precision(.fractionLength(2))) }
        }
        let nbsp = "\u{00A0}"
        #expect(text(nil, iob: nil) == "2.00\(nbsp)U")
        #expect(text(.wait, iob: "0.24") == "2.00\(nbsp)U")
        #expect(text(.count, iob: "0.24") == "2.00\(nbsp)U plus 0.24\(nbsp)U on board")
        #expect(text(.count, iob: "0") == "2.00\(nbsp)U plus 0.00\(nbsp)U on board")
        #expect(text(.count, iob: "-0.3") == "2.00\(nbsp)U less 0.30\(nbsp)U Trio held back")
        // Counted but unread, there are no units to judge by.
        #expect(text(.count, iob: nil) == nil)
        #expect(ISFTestEvaluator.unitsText(of: finished(units: nil)) { "\($0)" } == nil)
    }

    @Test(
        "A test saved before settling was kept decodes and carries on from Start, judged on its bolus"
    ) func decodesStateFromBeforeSettling() throws {
        let json = """
        {
          "id": "7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
          "phase": "waiting",
          "startedAt": "2027-01-15T08:00:00Z",
          "previousMode": "closed",
          "sessionID": "5C1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
          "isf": 50,
          "target": 100,
          "bolusAt": "2027-01-15T08:20:00Z",
          "bolusUnits": 2,
          "startGlucose": 212,
          "readings": []
        }
        """
        let decoded = try JSONCoding.decoder.decode(ISFTestState.self, from: Data(json.utf8))
        let startedAt = try #require(decoded.bolusWindowStart)
        #expect(decoded.phase == .waiting)
        #expect(decoded.settledAt == nil)
        #expect(startedAt == decoded.startedAt)
        #expect(decoded.doseDeadline == decoded.startedAt.addingTimeInterval(ISFTest.Config.doseAllowance))
        #expect(decoded.noBolusDeadline == decoded.doseDeadline)
        #expect(decoded.expectedDose == nil)
        #expect(decoded.iobLine == nil)
        #expect(decoded.iobHandling == nil)
        #expect(decoded.plannedPhase == nil)
        #expect(decoded.iobAtBolus == nil)
        #expect(decoded.iobAtEnd == nil)
        #expect(decoded.targetEntries == nil)
        #expect(decoded.tabletsGlucose == nil)
        #expect(ISFTestEvaluator.givenUnits(of: decoded) == 2)
        // Still waiting: what is left at the end is read when it finishes.
        #expect(ISFTestEvaluator.judgedUnits(of: decoded) == nil)
        #expect(!ISFTestEvaluator.iobUnread(of: decoded))
    }

    @Test("A settling test comes back the same, with what Begin fixed for insulin on board") func decodesSettlingState() throws {
        var state = ISFTestState(phase: .settling, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
        state.sessionID = testSession
        state.expectedDose = dec("2.24")
        state.iobLine = dec("0.112")
        state.iobHandling = .count
        state.plannedPhase = .dosing
        let decoded = try JSONCoding.decoder.decode(ISFTestState.self, from: JSONCoding.encoder.encode(state))
        #expect(decoded == state)

        var settled = state
        settled.phase = .waiting
        settled.settledAt = at(600)
        settled.bolusAt = at(1200)
        settled.bolusUnits = 2
        settled.iobAtBolus = dec("-0.3")
        let decodedSettled = try JSONCoding.decoder.decode(ISFTestState.self, from: JSONCoding.encoder.encode(settled))
        #expect(decodedSettled == settled)
        #expect(decodedSettled.doseDeadline == at(600 + ISFTest.Config.doseAllowance))
    }

    // MARK: After the adversarial review: verdicts

    @Test(
        "Judged on the insulin that acted: 200 to 114 on 2.00 U with 0.29 U left at 4 h and an ISF of 50 is accurate"
    ) func judgedOnInsulinThatActed() throws {
        var state = finished(start: 200, end: 114, units: 2, left: dec("0.29"))
        // 86 mg/dL on the 1.71 U that acted is 50.3 per unit: accurate, where the whole 2 U would read 43, too high.
        #expect(ISFTestEvaluator.judgedUnits(of: state) == dec("1.71"))
        #expect(state.outcome == .accurate)
        let evaluation = try #require(ISFTestEvaluator.evaluation(of: state))
        #expect(evaluation.outcome == .accurate)
        #expect(evaluation.direction == .keep)
        #expect(BasalTestEvaluator.towardZero(try #require(evaluation.dropPerUnit), scale: 1) == dec("50.2"))
        #expect(finished(start: 200, end: 114, units: 2).outcome == .tooHigh)
        // The band and the expected end use the same units: 200 − 1.71 × 50 is 114.5.
        #expect(
            ISFTestEvaluator.resultBand(of: state) == ISFTestEvaluator
                .accurateEnds(startGlucose: 200, units: dec("1.71"), isf: 50)
        )
        #expect(ISFTestEvaluator.expectedEndAwayFromTarget(of: state) == dec("114.5"))
        #expect(ISFTestEvaluator.noVerdict(for: state) == nil)

        // Not read: no verdict, with the unread-history wording.
        state.iobAtEnd = nil
        #expect(ISFTestEvaluator.evaluation(of: state)?.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: state) == .historyUnread)
        #expect(ISFTestEvaluator.resultBand(of: state) == nil)

        // With Count It, the insulin on board at the bolus is added before what is left is taken off.
        var counted = finished(start: 212, end: 100, units: 2, left: dec("0.3"))
        counted.iobHandling = .count
        counted.iobAtBolus = dec("0.24")
        #expect(ISFTestEvaluator.judgedUnits(of: counted) == dec("1.94"))
    }

    @Test(
        "What is left at 4 h is the newest determination's at or before the planned end, from the 12 minutes before it"
    ) func iobLeftAtTheEnd() {
        func determination(_ seconds: TimeInterval, _ iob: String?) -> ISFTestDetermination {
            ISFTestDetermination(date: plannedEnd.addingTimeInterval(seconds), iob: iob.map(dec))
        }
        let maxAge = BasalTest.Config.endReadingMaxAge
        #expect(
            ISFTestEvaluator.iobAtEnd([determination(-600, "0.35"), determination(-300, "0.3")], plannedEnd: plannedEnd)
                == dec("0.3")
        )
        // One at the same moment as the planned end is at it; one after it isn't the 4 hours'.
        #expect(
            ISFTestEvaluator.iobAtEnd([determination(-300, "0.3"), determination(0.5, "0.29")], plannedEnd: plannedEnd)
                == dec("0.29")
        )
        #expect(
            ISFTestEvaluator.iobAtEnd([determination(-300, "0.3"), determination(120, "0.2")], plannedEnd: plannedEnd)
                == dec("0.3")
        )
        // Signed, and one with no amount is passed over.
        #expect(
            ISFTestEvaluator.iobAtEnd([determination(-300, "-0.05"), determination(-60, nil)], plannedEnd: plannedEnd)
                == dec("-0.05")
        )
        // Exactly 12 minutes before counts; older, or none, is unread.
        #expect(ISFTestEvaluator.iobAtEnd([determination(-maxAge, "0.3")], plannedEnd: plannedEnd) == dec("0.3"))
        #expect(ISFTestEvaluator.iobAtEnd([determination(-maxAge - 2, "0.3")], plannedEnd: plannedEnd) == nil)
        #expect(ISFTestEvaluator.iobAtEnd([determination(120, "0.2")], plannedEnd: plannedEnd) == nil)
        #expect(ISFTestEvaluator.iobAtEnd([], plannedEnd: plannedEnd) == nil)
    }

    @Test(
        "Begin at 05:30 under ISF 60 and bolus at 06:25 under ISF 40: the dose and the result use 40"
    ) func settingsAtTheBolus() {
        let begin = time(5, 30)
        let isf = [entry(0, 360, 60), entry(360, 1440, 40)]
        let targets = [entry(0, 360, 110), entry(360, 1440, 100)]
        var state = ISFTestState(phase: .dosing, startedAt: begin, previousMode: .closed, isf: 60, target: 110)
        state.coveredEntries = ISFTestEvaluator.coveredAtBegin(isf, startedAt: begin, calendar: utc)
        state.targetEntries = ISFTestEvaluator.coveredAtBegin(targets, startedAt: begin, calendar: utc)
        #expect(state.targetEntries == targets)

        // The Dose step works the dose out with the ISF and target in force when it does.
        let bolusAt = time(6, 25)
        let settings = ISFTestEvaluator.doseSettings(of: state, at: bolusAt, calendar: utc)
        #expect(settings.isf == 40)
        #expect(settings.target == 100)
        #expect(ISFTestEvaluator.doseSettings(of: state, at: time(5, 59), calendar: utc).isf == 60)
        // And the result with those in force at the bolus, the ISF schedule narrowed to its 4 hours.
        let moved = ISFTestEvaluator.atBolus(state, bolusAt: bolusAt, calendar: utc)
        #expect(moved.isf == 40)
        #expect(moved.target == 100)
        #expect(moved.coveredEntries == [entry(360, 1440, 40)])
        // So the docs' dose from 200 is (200 − 100) ÷ 40, and it is judged per unit against 40.
        #expect(ISFTestEvaluator.dose(glucose: 200, target: settings.target, isf: settings.isf) == dec("2.5"))
        // Settling moves on from the target in force as it ends.
        state.targetEntries = [entry(0, 360, 160), entry(360, 1440, 100)]
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: 140, at: time(5, 45), calendar: utc) == .dosing)
        #expect(ISFTestEvaluator.phaseAfterSettling(state, glucose: 140, at: time(6, 5), calendar: utc) == .raising)

        // A state saved before the schedules were kept keeps what Start saved.
        let old = ISFTestState(phase: .dosing, startedAt: begin, previousMode: .closed, isf: 60, target: 110)
        #expect(ISFTestEvaluator.doseSettings(of: old, at: bolusAt, calendar: utc).isf == 60)
        #expect(ISFTestEvaluator.doseSettings(of: old, at: bolusAt, calendar: utc).target == 110)
        #expect(ISFTestEvaluator.atBolus(old, bolusAt: bolusAt, calendar: utc).isf == 60)
        #expect(ISFTestEvaluator.scheduleValue(in: nil, at: bolusAt, calendar: utc) == nil)
    }

    @Test("A target schedule becomes entries in mg/dL that run to the next start, the low end of each range") func targetEntries() {
        let mgdl = BGTargets(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            targets: [
                BGTargetEntry(low: 110, high: 120, start: "06:00", offset: 360),
                BGTargetEntry(low: 100, high: 110, start: "00:00", offset: 0)
            ]
        )
        #expect(ISFTest.Provider.targetEntries(in: mgdl) == [entry(0, 360, 100), entry(360, 1440, 110)])
        let mmol = BGTargets(
            units: .mmolL,
            userPreferredUnits: .mmolL,
            targets: [BGTargetEntry(low: 5.5, high: 5.5, start: "00:00", offset: 0)]
        )
        // Converted as the target at a time is, so the two never disagree.
        #expect(ISFTest.Provider.targetEntries(in: mmol) == [entry(0, 1440, Decimal(5.5).asMgdL)])
        #expect(ISFTest.Provider.targetEntries(in: mmol).first?.value == ISFTest.Provider.target(in: mmol, at: Date()))
        #expect(ISFTest.Provider.targetEntries(in: BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])).isEmpty)
    }

    @Test(
        "A dose too small for any whole reading to count as accurate gives no verdict; the line follows the dose shown"
    ) func tinyDoses() {
        // 0.11 U × 50 is 5.5 mg/dL: no whole reading lies within a step of 144.5.
        let tiny = finished(start: 150, end: 145, units: dec("0.11"))
        #expect(tiny.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: tiny) == .doseTooSmall)
        #expect(evaluate(start: 150, end: 100, units: dec("0.11")).outcome == .inconclusive)
        // 0.4 U still has one: 130.
        #expect(finished(start: 150, end: 130, units: dec("0.4")).outcome == .accurate)
        #expect(ISFTestEvaluator.noVerdict(for: finished(start: 150, end: 120, units: dec("0.4"))) == nil)

        // Insulin on board is held against 5% of the dose the Dose step shows, not the one Begin expected.
        #expect(ISFTestEvaluator.doseIOBLine(dose: dec("0.8"), handling: .wait) == dec("0.04"))
        #expect(ISFTestEvaluator.doseIOBLine(dose: dec("0.8"), handling: nil) == dec("0.04"))
        #expect(ISFTestEvaluator.doseIOBLine(dose: dec("0.8"), handling: .count) == nil)
        #expect(ISFTestEvaluator.doseIOBLine(dose: nil, handling: .wait) == nil)
        // Begin expected 2.24 U (line 0.11 U); glucose came down to give 0.80 U, so 0.08 U on board now holds it up.
        #expect(
            !ISFTestEvaluator
                .waitsForIOB(iob: dec("0.08"), line: ISFTestEvaluator.iobLine(expectedDose: dec("2.24")), handling: .wait)
        )
        #expect(!ISFTestEvaluator.iobAllowsDose(iob: dec("0.08"), dose: dec("0.8"), handling: .wait))
        #expect(!ISFTestEvaluator.iobAllowsDose(iob: dec("-0.08"), dose: dec("0.8"), handling: nil))
        #expect(ISFTestEvaluator.iobAllowsDose(iob: dec("0.04"), dose: dec("0.8"), handling: .wait))
        #expect(!ISFTestEvaluator.iobAllowsDose(iob: nil, dose: dec("0.8"), handling: .wait))
        // Counting it, the dose takes it off instead.
        #expect(ISFTestEvaluator.iobAllowsDose(iob: dec("0.5"), dose: dec("0.8"), handling: .count))
        #expect(ISFTestEvaluator.iobAllowsDose(iob: dec("0.5"), dose: nil, handling: .wait))
    }

    @Test(
        "A suspend is too low only with glucose at or below the target; a forecast suspend above it gives no verdict"
    ) func forecastSuspend() {
        func why(end: Int?, target: Decimal = 100, units: Decimal? = dec("2.24"), start: Int? = 212) -> ISFTestNoVerdict? {
            ISFTestEvaluator.lowNoVerdict(
                glucoseAtSuspend: end,
                startGlucose: start,
                givenUnits: units,
                target: target,
                isf: 50,
                increment: 0
            )
        }
        #expect(why(end: 60) == nil)
        #expect(why(end: 100) == nil)
        #expect(why(end: 101) == .forecastSuspend)
        #expect(why(end: 140) == .forecastSuspend)
        #expect(why(end: nil) == .noReadings)
        #expect(evaluate(end: 120, elapsedHours: 1, reason: .low).outcome == .inconclusive)
        let above = finished(end: 120, elapsedHours: 1, reason: .low)
        #expect(above.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: above) == .forecastSuspend)
        let below = finished(end: 95, elapsedHours: 1, reason: .low)
        #expect(below.outcome == .tooLow)
        #expect(ISFTestEvaluator.noVerdict(for: below) == nil)

        // The glucose at the suspend is the mean of the 3 readings at or before it, from before the bolus too, so a
        // suspend soon after the bolus has one.
        func reading(_ seconds: TimeInterval, _ glucose: Int) -> BasalTestReading {
            BasalTestReading(date: at(seconds), glucose: glucose)
        }
        let bolusAt = at(1200)
        let fetched = [reading(600, 130), reading(900, 120), reading(1200, 110), reading(1500, 100), reading(1800, 90)]
        #expect(ISFTestEvaluator.endGlucose(fetched, bolusAt: bolusAt, end: at(1500), reason: .low) == 110)
        // At the same moment as the saved end counts as at it.
        #expect(ISFTestEvaluator.endGlucose(fetched, bolusAt: bolusAt, end: at(1499.5), reason: .low) == 110)
        // Not a low: only readings from the bolus on.
        #expect(ISFTestEvaluator.endGlucose(fetched, bolusAt: bolusAt, end: at(1500), reason: .completed) == 105)
        #expect(ISFTestEvaluator.endGlucose(fetched, bolusAt: bolusAt, end: at(1800), reason: .completed) == 100)
        // Without a bolus, or a reading recent enough, none.
        #expect(ISFTestEvaluator.endGlucose(fetched, bolusAt: nil, end: at(1500), reason: .low) == nil)
        #expect(ISFTestEvaluator.endGlucose(fetched, bolusAt: bolusAt, end: at(1800 + 13 * 60), reason: .low) == nil)
    }

    @Test(
        "A low after more than a docs step over the docs' dose at the bolus gives no verdict"
    ) func lowAfterMoreThanTheDocsDose() {
        func why(units: Decimal?, start: Int? = 212, end: Int = 60) -> ISFTestNoVerdict? {
            ISFTestEvaluator.lowNoVerdict(
                glucoseAtSuspend: end,
                startGlucose: start,
                givenUnits: units,
                target: 100,
                isf: 50,
                increment: 0
            )
        }
        // The docs' dose from 212 is 2.24 U; a step over it is 2.352 U.
        #expect(why(units: dec("2.24")) == nil)
        #expect(why(units: dec("2.35")) == nil)
        #expect(why(units: dec("2.36")) == .doseOverDocs)
        // Trio's 120% suggestion, tapped.
        #expect(why(units: dec("2.69")) == .doseOverDocs)
        // Less than the docs' dose is still a low the ISF explains.
        #expect(why(units: dec("1.79")) == nil)
        // At or below the target at the bolus there was no dose to give.
        #expect(why(units: dec("0.5"), start: 100) == .doseOverDocs)
        // Without the units or the start, it can't be told.
        #expect(why(units: nil) == .noAmount)
        #expect(why(units: 2, start: nil) == .noReadings)

        let over = finished(end: 60, units: dec("2.69"), elapsedHours: 1, reason: .low)
        #expect(over.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: over) == .doseOverDocs)
        // Counted, what went in is the bolus and the insulin on board at it.
        var counted = finished(end: 60, units: 2, elapsedHours: 1, reason: .low)
        counted.iobHandling = .count
        counted.iobAtBolus = dec("0.6")
        #expect(ISFTestEvaluator.noVerdict(for: counted) == .doseOverDocs)
        counted.iobAtBolus = dec("0.24")
        #expect(ISFTestEvaluator.noVerdict(for: counted) == nil)
        #expect(ISFTestEvaluator.evaluation(of: counted)?.outcome == .tooLow)
    }

    @Test("Settling waits for 3 CGM readings after Trio's first loop in Basal Testing") func settlingWaitsForReadings() {
        #expect(ISFTest.Config.settleReadings == 3)
        // The loop at 330 s; readings every 5 minutes from Begin.
        #expect(settle([330], readings: [0, 300, 600, 900], now: 900) == .waiting(loopedAt: at(330), waitsForIOB: false))
        #expect(settle([330], readings: [0, 300, 600, 900, 1200], now: 1200) == .settled)
        // A reading before the loop, or at it, doesn't count.
        #expect(ISFTestEvaluator.readingsAfterLoop([0, 300, 329.5, 330.5, 600].map(at), loopedAt: at(330)) == 1)
        #expect(settle([330], readings: [0, 300, 330.5, 600, 900], now: 900) == .waiting(loopedAt: at(330), waitsForIOB: false))
        #expect(settle([330], readings: [0, 300, 332, 600, 900], now: 900) == .settled)
        // Insulin on board still counts on top.
        #expect(settle([330], readings: [600, 900, 1200], iob: "0.3", handling: .wait) == .waiting(
            loopedAt: at(330),
            waitsForIOB: true
        ))
        // The hour runs out with the loop done but too few readings: like no loop, Cancel only.
        let allowance = ISFTest.Config.settleAllowance
        #expect(settle([330], readings: [600, 900], now: allowance) == .tooFewReadings(loopedAt: at(330)))
        #expect(settle([330], readings: [600, 900], iob: "0.3", handling: .wait, now: allowance) == .tooFewReadings(
            loopedAt: at(330)
        ))
        // With enough of them, insulin on board still over the line asks, as before.
        #expect(settle([330], readings: [600, 900, 1200], iob: "0.3", handling: .wait, now: allowance) == .timeUp(
            loopedAt: at(330)
        ))
        #expect(settle([], readings: [600, 900, 1200], now: allowance) == .noLoop)
    }

    // MARK: After the adversarial review: safety and the mode

    @Test(
        "The pump suspended, alarmed or changed during the test ends it as interrupted, before the bolus and after it"
    ) func pumpInterruptionEndsTheTest() {
        // The service's record of it, before the bolus and while waiting, with the usual mode already back.
        #expect(check(.dosing, ended: serviceEnd(.pumpInterrupted, after: 900), now: 960, mode: .closed) == .pumpInterrupted(
            at: at(900)
        ))
        #expect(check(.settling, ended: serviceEnd(.pumpInterrupted, after: 300), now: 360, mode: .closed) == .pumpInterrupted(
            at: at(300)
        ))
        #expect(check(.waiting, ended: serviceEnd(.pumpInterrupted, after: 3600), now: 3660, mode: .closed) == .pumpInterrupted(
            at: at(3600)
        ))
        // Another session's isn't this test's.
        #expect(
            check(.waiting, ended: serviceEnd(.pumpInterrupted, after: 3600, session: UUID()), now: 3660, mode: .closed)
                == .modeChanged
        )
        #expect(ISFTestEvaluator.decidable(.pumpInterrupted(at: at(900)), bolusesRead: false) == .pumpInterrupted(at: at(900)))
        // A finished test with it has no verdict.
        var state = finished(elapsedHours: 2, reason: .interrupted, interference: ISFTestEvaluator.pumpInterruptedNote)
        #expect(state.outcome == .invalid)
        #expect(ISFTestEvaluator.noVerdict(for: state) == .interrupted)
        state.interference = nil
        #expect(ISFTestEvaluator.noVerdict(for: state) == .interrupted)
        // The basal fast reads the cause as basal stopped, should a basal session ever get it.
        #expect(BasalTestEvaluator.runningCheck(
            sessionID: testSession,
            serviceEnd: serviceEnd(.pumpInterrupted, after: 900),
            suspend: .none,
            now: at(960),
            plannedEnd: at(4 * hour),
            mode: .closed
        ) == .unexplainedSuspend(at: at(900)))
    }

    @Test("The service's record of a mode change ends the test with the mode-change words") func serviceModeChanged() {
        // Picked back in Basal Testing by the user: the mode reads as Basal Testing, but the record says it was left.
        #expect(check(.dosing, ended: serviceEnd(.modeChanged, after: 900), now: 960) == .modeChanged)
        #expect(check(.settling, ended: serviceEnd(.modeChanged, after: 300), now: 360) == .modeChanged)
        #expect(check(.waiting, ended: serviceEnd(.modeChanged, after: 3600), now: 3660) == .modeChanged)
        #expect(
            ISFTestEvaluator.ending(for: .modeChanged, doseDeadline: doseDeadline).note
                == "The dosing mode changed during the test."
        )
    }

    @Test("Begin waits while the pump is suspended, and at a high target with glucose at or below it") func beginBlocks() {
        #expect(ISFTestEvaluator.pumpBlocksBegin(.suspended))
        #expect(!ISFTestEvaluator.pumpBlocksBegin(.delivering))
        #expect(!ISFTestEvaluator.pumpBlocksBegin(.tempBasal))
        // A state that can't be read doesn't: the devices check covers a missing pump.
        #expect(!ISFTestEvaluator.pumpBlocksBegin(nil))
        // The pump's own states, as the test reads them.
        let now = Date()
        #expect(ISFTest.Provider.pumpDelivery(for: .active(now)) == .delivering)
        #expect(ISFTest.Provider.pumpDelivery(for: .active(.distantPast)) == nil)
        #expect(ISFTest.Provider.pumpDelivery(for: nil) == nil)
        let stopped: [PumpManagerStatus.BasalDeliveryState] = [.suspended(now), .suspending, .resuming, .pumpInoperable]
        for state in stopped {
            #expect(ISFTest.Provider.pumpDelivery(for: state) == .suspended)
        }
        let temp = DoseEntry(
            type: .tempBasal,
            startDate: now,
            endDate: now.addingTimeInterval(1800),
            value: 0,
            unit: .unitsPerHour,
            decisionId: nil
        )
        let temps: [PumpManagerStatus.BasalDeliveryState] = [.tempBasal(temp), .initiatingTempBasal, .cancelingTempBasal]
        for state in temps {
            #expect(ISFTest.Provider.pumpDelivery(for: state) == .tempBasal)
        }

        // At a target of 150 or more with glucose at or below it there is no dose and nothing for tablets to aim for.
        #expect(ISFTestEvaluator.noDoseBlocksBegin(startPath: .noDose))
        #expect(ISFTestEvaluator.noDoseBlocksBegin(startPath: ISFTestEvaluator.startPath(glucose: 140, target: 150)))
        #expect(!ISFTestEvaluator.noDoseBlocksBegin(startPath: .dose))
        #expect(!ISFTestEvaluator.noDoseBlocksBegin(startPath: .raise))
        #expect(!ISFTestEvaluator.noDoseBlocksBegin(startPath: nil))
        // So no test starts there without an expected dose, which the insulin on board checks need.
        #expect(ISFTestEvaluator.expectedDose(startPath: .noDose, glucose: 140, target: 150, isf: 50) == nil)
    }

    @Test(
        "A zero temp counts as Trio's low only when a determination from a minute after Begin asked for it"
    ) func suspendFromTheFirstBasalTestingLoop() {
        func temp(_ seconds: TimeInterval, rate: Decimal = 0, minutes: Int = 30) -> BasalTestTempBasal {
            BasalTestTempBasal(date: at(seconds), rate: rate, minutes: minutes)
        }
        func reading(_ temps: [BasalTestTempBasal], asked: [TimeInterval]) -> BasalTestEvaluator.SuspendReading {
            ISFTestEvaluator.suspendReading(
                temps,
                zeroTempDeterminations: asked.map(at),
                startedAt: testStart,
                until: at(4 * hour)
            )
        }
        #expect(ISFTest.Config.settleLoopMargin == 60)
        // Closed Loop decided it before Begin, the pump started it 10 seconds after: settling's, not a low.
        #expect(reading([temp(10)], asked: [-20]) == .none)
        #expect(reading([temp(10)], asked: [30]) == .none)
        // Basal Testing's own loop asked for it.
        #expect(reading([temp(90)], asked: [60]) == .suspended(at: at(90)))
        #expect(reading([temp(10)], asked: [-20, 60]) == .suspended(at: at(10)))
        // Nobody asked: set on the pump.
        #expect(reading([temp(900)], asked: []) == .unexplained(at: at(900)))
        // Closed Loop's doesn't hide what follows it.
        #expect(reading([temp(10), temp(1800)], asked: [-20, 1770]) == .suspended(at: at(1800)))
        #expect(reading([temp(10), temp(1800)], asked: [-20]) == .unexplained(at: at(1800)))
        // A cancel, a temp that delivers, and one before Begin aren't suspends.
        #expect(reading([temp(600, minutes: 0), temp(900, rate: dec("0.4")), temp(-300)], asked: [580, 880, -330]) == .none)
        // As for the basal fast, the first zero temp a loop in Basal Testing asked for decides.
        #expect(reading([temp(600), temp(1200)], asked: [570]) == .suspended(at: at(600)))
    }

    @Test(
        "Settling waits while a temp basal runs on the pump; unread, it doesn't hold it up; at the hour, Cancel only"
    ) func settlingWaitsForTempBasal() {
        #expect(settle([330], tempBasalRunning: true) == .waiting(loopedAt: at(330), waitsForIOB: false))
        #expect(settle([330], tempBasalRunning: false) == .settled)
        #expect(settle([330], tempBasalRunning: nil) == .settled)
        let allowance = ISFTest.Config.settleAllowance
        #expect(settle([330], tempBasalRunning: true, now: allowance) == .tempBasalRunning(loopedAt: at(330)))
        // Waiting for insulin on board too, the temp basal is what time up is about: counting can't end it.
        #expect(settle([330], tempBasalRunning: true, iob: "0.3", handling: .wait, now: allowance) == .tempBasalRunning(
            loopedAt: at(330)
        ))
        // The loop and the readings come first.
        #expect(settle([], tempBasalRunning: true, now: allowance) == .noLoop)
        #expect(settle([330], readings: [600], tempBasalRunning: true, now: allowance) == .tooFewReadings(loopedAt: at(330)))
    }

    @Test(
        "A lost session with Basal Testing still on: the runner puts the mode back itself, and only then"
    ) func lostSessionRestore() {
        let other = UUID()
        func restore(
            mode: DosingMode = .basalTesting,
            active: UUID? = nil,
            lastEnd: UUID? = nil,
            previous: DosingMode = .closed
        ) -> DosingMode? {
            SettingsTestModeRule.modeToRestore(
                mode: mode,
                testSessionID: testSession,
                activeSessionID: active,
                lastEndSessionID: lastEnd,
                previousMode: previous
            )
        }
        // No session runs and the service kept no end of this one: nothing else will put the usual mode back.
        #expect(restore() == .closed)
        #expect(restore(lastEnd: other) == .closed)
        #expect(restore(previous: .lowGlucoseSuspend) == .lowGlucoseSuspend)
        // The session still runs: ending it puts the mode back. Another test's owns Basal Testing.
        #expect(restore(active: testSession) == nil)
        #expect(restore(active: other) == nil)
        // The service ended it: it put the mode back then, or the mode is the user's.
        #expect(restore(lastEnd: testSession) == nil)
        // Basal Testing is already off.
        #expect(restore(mode: .closed) == nil)
        // A test with no session never switched modes.
        #expect(SettingsTestModeRule.modeToRestore(
            mode: .basalTesting,
            testSessionID: nil,
            activeSessionID: nil,
            lastEndSessionID: nil,
            previousMode: .closed
        ) == nil)
        #expect(restore(previous: .basalTesting) == nil)

        // The Result says Basal Testing is still on only when no test runs it.
        #expect(SettingsTestModeRule.basalTestingLeftOn(mode: .basalTesting, activeSessionID: nil))
        #expect(!SettingsTestModeRule.basalTestingLeftOn(mode: .basalTesting, activeSessionID: other))
        #expect(!SettingsTestModeRule.basalTestingLeftOn(mode: .closed, activeSessionID: nil))
    }

    // MARK: Fix round 1

    /// The conditions at a bolus 20 minutes after Start: by default a start glucose of 210 against a target of 100 and an
    /// ISF of 50 (a docs dose of 2.20 U, a line for insulin on board of 0.11 U), a level arrow 2 minutes before it, and a
    /// determination 3 minutes before it with no carbs and no insulin on board.
    private func condition(
        startGlucose: Int? = 210,
        target: Decimal = 100,
        isf: Decimal = 50,
        readings: [BasalTestReading]? = [],
        tabletsTakenAt: TimeInterval? = nil,
        tabletsGlucose: Int? = 110,
        arrow: ISFTestArrowReading?? =
            .some(ISFTestArrowReading(date: Date(timeIntervalSince1970: 1_800_000_000 + 1080), direction: .flat)),
        determinations: [ISFTestDetermination]? = [
            ISFTestDetermination(date: Date(timeIntervalSince1970: 1_800_000_000 + 1020), iob: 0, cob: 0)
        ],
        handling: ISFTestIOBHandling? = nil
    ) -> ISFTestBolusCondition? {
        ISFTestEvaluator.failedBolusCondition(
            bolusAt: at(1200),
            startGlucose: startGlucose,
            target: target,
            isf: isf,
            readings: readings,
            tabletsTakenAt: tabletsTakenAt.map(at),
            tabletsGlucose: tabletsGlucose,
            arrow: arrow ?? nil,
            determinations: determinations,
            handling: handling
        )
    }

    @Test("A bolus is judged only if what the Dose step holds the dose for held at the bolus") func conditionsAtTheBolus() {
        func reading(_ seconds: TimeInterval, _ glucose: Int) -> BasalTestReading {
            BasalTestReading(date: at(seconds), glucose: glucose)
        }
        func determination(_ seconds: TimeInterval, iob: String, cob: Decimal?) -> ISFTestDetermination {
            ISFTestDetermination(date: at(seconds), iob: dec(iob), cob: cob)
        }
        func arrow(_ seconds: TimeInterval, _ direction: BloodGlucose.Direction?) -> ISFTestArrowReading {
            ISFTestArrowReading(date: at(seconds), direction: direction)
        }
        // All held.
        #expect(condition() == nil)

        // The tablets hadn't acted on the readings at or before the bolus.
        let before = [reading(300, 110), reading(590, 110)]
        let rose = [reading(700, 118), reading(800, 126), reading(900, 128)]
        #expect(condition(readings: before + [reading(700, 111)], tabletsTakenAt: 600) == .tabletsNotActed)
        #expect(condition(readings: before + rose, tabletsTakenAt: 600) == nil)
        // A rise that only came after the bolus doesn't count.
        let late = [reading(1300, 118), reading(1400, 126), reading(1500, 128)]
        #expect(condition(readings: before + late, tabletsTakenAt: 600) == .tabletsNotActed)
        // Without tablets there is nothing to have acted.
        #expect(condition(readings: before) == nil)

        // The arrow at the bolus was moving; none from a CGM that gives none is level (R6).
        #expect(condition(arrow: arrow(1080, .singleUp)) == .glucoseMoving)
        #expect(condition(arrow: arrow(1080, .fortyFiveDown)) == .glucoseMoving)
        #expect(condition(arrow: arrow(1080, nil)) == nil)
        #expect(condition(arrow: arrow(1080, BloodGlucose.Direction.none)) == nil)

        // Carbs on board at the bolus.
        #expect(condition(determinations: [determination(1020, iob: "0", cob: 8)]) == .carbsOnBoard)

        // Waiting for insulin on board, over the line at the bolus; counting it, the dose took it off.
        let over = [determination(1020, iob: "0.3", cob: 0)]
        #expect(condition(determinations: over, handling: .wait) == .iobOverLine)
        #expect(condition(determinations: over, handling: nil) == .iobOverLine)
        #expect(condition(determinations: over, handling: .count) == nil)
        #expect(condition(determinations: [determination(1020, iob: "0.11", cob: 0)], handling: .wait) == nil)
        #expect(condition(determinations: [determination(1020, iob: "-0.2", cob: 0)], handling: .wait) == .iobOverLine)

        // Each sentence the Result shows.
        #expect(
            ISFTestBolusCondition.tabletsNotActed.note
                == "The bolus came before the tablets raised your glucose, so the test can't be judged."
        )
        #expect(
            ISFTestBolusCondition.glucoseMoving.note
                == "The bolus came while your glucose was still moving, so the test can't be judged."
        )
        #expect(ISFTestBolusCondition.carbsOnBoard.note == "The bolus came with carbs on board, so the test can't be judged.")
        #expect(
            ISFTestBolusCondition.iobOverLine.note
                == "The bolus came with more insulin on board than the test allows, so the test can't be judged."
        )
    }

    @Test(
        "A condition that can't be checked at the bolus leaves no verdict, with the unread-history wording"
    ) func conditionsUnread() {
        func determination(_ seconds: TimeInterval, iob: String?, cob: Decimal?) -> ISFTestDetermination {
            ISFTestDetermination(date: at(seconds), iob: iob.map(dec), cob: cob)
        }
        // No reading at or just before the bolus, or one more than 12 minutes before it, or one after it.
        #expect(condition(arrow: .some(nil)) == .unread)
        #expect(condition(arrow: ISFTestArrowReading(date: at(1200 - 12 * 60 - 2), direction: .flat)) == .unread)
        #expect(condition(arrow: ISFTestArrowReading(date: at(1260), direction: .flat)) == .unread)
        // No determination that recent, or none read.
        #expect(condition(determinations: nil) == .unread)
        #expect(condition(determinations: [determination(1200 - 12 * 60 - 2, iob: "0", cob: 0)]) == .unread)
        // Carbs read, insulin on board not, in a test that waits for it.
        #expect(condition(determinations: [determination(1020, iob: nil, cob: 0)], handling: .wait) == .unread)
        // The readings for the tablets.
        #expect(condition(readings: nil, tabletsTakenAt: 600) == .unread)
        #expect(ISFTestBolusCondition.unread.note == ISFTestEvaluator.historyUnreadNote)
        #expect(
            ISFTestEvaluator.historyUnreadNote
                == "Trio couldn't read part of the history to check the test, so it can't say what your ISF did."
        )
        // A finished test ended for one has no verdict.
        let ended = finished(elapsedHours: 0.1, reason: .interrupted, interference: ISFTestBolusCondition.unread.note)
        #expect(ended.outcome == .invalid)
        #expect(ISFTestEvaluator.noVerdict(for: ended) == .interrupted)
    }

    // MARK: Rules at the bolus moment, and shared dose readiness

    @Test("A bolus at or below the target is a failed condition, checked first") func bolusAtOrBelowTarget() {
        #expect(condition(startGlucose: 100) == .atOrBelowTarget)
        #expect(
            condition(startGlucose: 95, arrow: .some(ISFTestArrowReading(date: at(1080), direction: .singleUp))) ==
                .atOrBelowTarget
        )
        #expect(condition(startGlucose: 101) == nil)
        // The target at the bolus is the one it is held against, not a fixed 100.
        #expect(condition(startGlucose: 150, target: 150) == .atOrBelowTarget)
        #expect(condition(startGlucose: 151, target: 150) == nil)
        #expect(
            ISFTestBolusCondition.atOrBelowTarget.note
                == "The bolus came with your glucose at or below your target, so the test can't be judged."
        )
    }

    @Test("A start glucose at the bolus that can't be read is unread, counted or not") func unreadStartGlucose() {
        #expect(condition(startGlucose: nil) == .unread)
        #expect(condition(startGlucose: nil, handling: .count) == .unread)
        // Checked before the other conditions, so what else held at the bolus doesn't make an unread start glucose read.
        #expect(condition(startGlucose: nil, arrow: .some(ISFTestArrowReading(date: at(1080), direction: .singleUp))) == .unread)
    }

    @Test("The line for insulin on board comes from the dose at the bolus moment") func lineFromTheBolusMoment() {
        func held(_ iob: String, start: Int, target: Decimal = 100, isf: Decimal = 50) -> ISFTestBolusCondition? {
            condition(
                startGlucose: start,
                target: target,
                isf: isf,
                determinations: [ISFTestDetermination(date: at(1020), iob: dec(iob), cob: 0)],
                handling: .wait
            )
        }
        // 210 against 100 at an ISF of 50 is a 2.20 U dose, and 5% of it a line of 0.11 U.
        #expect(held("0.11", start: 210) == nil)
        #expect(held("0.12", start: 210) == .iobOverLine)
        // A smaller dose, 1.20 U, a smaller line, 0.06 U.
        #expect(held("0.06", start: 160) == nil)
        #expect(held("0.07", start: 160) == .iobOverLine)
        // The target and ISF at the bolus: 60 ÷ 25 is 2.40 U, a line of 0.12 U.
        #expect(held("0.12", start: 210, target: 150, isf: 25) == nil)
        #expect(held("0.13", start: 210, target: 150, isf: 25) == .iobOverLine)
        // A test that counts insulin on board takes it off the dose instead, so there is no line.
        #expect(condition(
            startGlucose: 160,
            determinations: [ISFTestDetermination(date: at(1020), iob: dec("0.3"), cob: 0)],
            handling: .count
        ) == nil)
    }

    /// When the Dose step's readiness is judged. The raising test took tablets 20 minutes before it.
    private var doseNow: Date { at(2 * hour) }

    private func doseReading(_ minutesAgo: Double, _ glucose: Int) -> BasalTestReading {
        BasalTestReading(date: doseNow.addingTimeInterval(-minutesAgo * 60), glucose: glucose)
    }

    private func testState(_ phase: ISFTestPhase) -> ISFTestState {
        ISFTestState(phase: phase, startedAt: testStart, previousMode: .closed, isf: 50, target: 100)
    }

    /// Tablets taken 20 minutes before now, from 110 mg/dL.
    private var raising: ISFTestState {
        var state = testState(.raising)
        state.tabletsTakenAt = doseNow.addingTimeInterval(-20 * 60)
        state.tabletsGlucose = 110
        return state
    }

    /// Dosing, with no tablets, at an ISF of 50 and a target of 100, and no choice on insulin on board.
    private var dosing: ISFTestState { testState(.dosing) }

    /// After the tablets: 128 (2 minutes ago), 126, 118 and 110 from before they acted (25 minutes ago); a flat arrow,
    /// no insulin or carbs on board.
    private var inputs: ISFTestDoseInputs {
        ISFTestDoseInputs(
            readings: [doseReading(2, 128), doseReading(7, 126), doseReading(14, 118), doseReading(25, 110)],
            direction: .flat,
            iob: 0,
            doseIOB: nil,
            cob: 0,
            increment: dec("0.05"),
            now: doseNow
        )
    }

    /// Glucose at 210 mg/dL, level.
    private var inputs210: ISFTestDoseInputs {
        ISFTestDoseInputs(
            readings: [doseReading(2, 210), doseReading(7, 210), doseReading(12, 210)],
            direction: .flat,
            iob: 0,
            doseIOB: nil,
            cob: 0,
            increment: dec("0.05"),
            now: doseNow
        )
    }

    @Test("The Dose step's gate reads the same from the screen's inputs and the runner's") func doseReadinessFromInputs() {
        // Raising, tablets taken 20 minutes ago from 110: glucose has risen from them and is level.
        #expect(ISFTestEvaluator.canDose(of: raising, inputs))
        #expect(!ISFTestEvaluator.canDose(of: raising, inputs.with(direction: .singleUp)))
        #expect(!ISFTestEvaluator.canDose(of: raising, inputs.with(cob: nil)))
        #expect(ISFTestEvaluator.doseGlucose(inputs.with(newestAgo: 13 * 60)) == nil)
        #expect(ISFTestEvaluator.shownDirection(inputs.with(newestAgo: 16 * 60)) == nil)
        // Dosing at 210, target 100, ISF 50, handling nil.
        #expect(ISFTestEvaluator.docsDose(of: dosing, inputs210) == Decimal(string: "2.2"))
    }

    @Test("Raise moves on only with a reading recent enough to work the dose out from") func raiseNeedsARecentReading() {
        // Tablets taken 30 minutes ago from 110, and the 3 readings since have risen from them. With the newest 13 minutes
        // old the arrow still shows flat, but there is no glucose to work the dose out from, so the Dose step would show
        // none.
        var earlier = raising
        earlier.tabletsTakenAt = doseNow.addingTimeInterval(-30 * 60)
        let stale = inputs.with(newestAgo: 13 * 60)
        #expect(ISFTestEvaluator.tabletsActed(of: earlier, stale))
        #expect(ISFTestEvaluator.shownDirection(stale) == .flat)
        #expect(ISFTestEvaluator.doseGlucose(stale) == nil)
        #expect(!ISFTestEvaluator.canDose(of: earlier, stale))
        #expect(ISFTestEvaluator.canDose(of: earlier, inputs.with(newestAgo: 11 * 60)))
    }

    @Test("Each part of the Dose step's inputs counts, and a stale reading or arrow doesn't") func doseInputsEachCount() {
        // The mean of the newest 3 readings: 128, 126 and 118.
        #expect(ISFTestEvaluator.doseGlucose(inputs) == 124)
        #expect(ISFTestEvaluator.doseGlucose(inputs.with(newestAgo: 11 * 60)) == 124)
        #expect(ISFTestEvaluator.doseGlucose(inputs.with(readings: [])) == nil)
        // The arrow is the CGM's while the newest reading is within 15 minutes, and none after.
        #expect(ISFTestEvaluator.arrowMaxAge == 15 * 60)
        #expect(ISFTestEvaluator.shownDirection(inputs) == .flat)
        #expect(ISFTestEvaluator.shownDirection(inputs.with(newestAgo: 14 * 60)) == .flat)
        #expect(ISFTestEvaluator.shownDirection(inputs.with(readings: [])) == nil)
        #expect(ISFTestEvaluator.shownDirection(inputs.with(direction: .singleUp)) == .singleUp)

        // Tablets have acted only once taken, with the newest 3 readings after them above the glucose they were taken at.
        #expect(ISFTestEvaluator.tabletsActed(of: raising, inputs))
        #expect(!ISFTestEvaluator.tabletsActed(of: dosing, inputs))
        var risenTo130 = raising
        risenTo130.tabletsGlucose = 130
        #expect(!ISFTestEvaluator.tabletsActed(of: risenTo130, inputs))
        #expect(!ISFTestEvaluator.canDose(of: risenTo130, inputs))

        // Dosing: the docs' dose, level glucose, and insulin on board under the line (5% of 2.20 U is 0.11 U).
        #expect(ISFTestEvaluator.canDose(of: dosing, inputs210))
        #expect(!ISFTestEvaluator.canDose(of: dosing, inputs210.with(direction: .doubleUp)))
        #expect(!ISFTestEvaluator.canDose(of: dosing, inputs210.with(cob: 8)))
        #expect(ISFTestEvaluator.canDose(of: dosing, inputs210.with(iob: dec("0.11"))))
        #expect(!ISFTestEvaluator.canDose(of: dosing, inputs210.with(iob: dec("0.12"))))
        #expect(!ISFTestEvaluator.canDose(of: dosing, inputs210.with(iob: nil)))
        // A reading too old to count leaves nothing to dose from, though the arrow is still level.
        #expect(ISFTestEvaluator.docsDose(of: dosing, inputs210.with(newestAgo: 13 * 60)) == nil)
        #expect(!ISFTestEvaluator.canDose(of: dosing, inputs210.with(newestAgo: 13 * 60)))
        // At or below the target there is no dose, so nothing to give.
        #expect(ISFTestEvaluator.docsDose(of: dosing, inputs210.with(readings: [doseReading(2, 100)])) == nil)
        #expect(!ISFTestEvaluator.canDose(of: dosing, inputs210.with(readings: [doseReading(2, 100)])))
        // Carbs not read: no dose, whatever glucose is.
        #expect(ISFTestEvaluator.docsDose(of: dosing, inputs210.with(cob: nil)) == nil)

        // Counting insulin on board takes the insulin on board from Trio's determination off the correction.
        var counting = dosing
        counting.iobHandling = .count
        #expect(ISFTestEvaluator.docsDose(of: counting, inputs210.with(doseIOB: dec("0.5"))) == dec("1.7"))
        #expect(ISFTestEvaluator.docsDose(of: counting, inputs210) == nil)
        // The pump's increment: a dose under it is none.
        #expect(ISFTestEvaluator.docsDose(of: counting, inputs210.with(doseIOB: dec("2.17"))) == nil)
        // Any phase after the bolus never doses.
        #expect(!ISFTestEvaluator.canDose(of: testState(.waiting), inputs210))
        #expect(!ISFTestEvaluator.canDose(of: testState(.finished), inputs210))
    }

    /// A test that finished one way or another, for the sentences the Result gives.
    private var noBolusTest: ISFTestState {
        finished(start: nil, end: nil, elapsedHours: 1.5, reason: .noBolus, bolus: false)
    }

    private var interrupted: ISFTestState {
        finished(elapsedHours: 0.1, reason: .interrupted, interference: "Carbs were logged during the test.")
    }

    private var endedAfterOneHour: ISFTestState { finished(end: 130, elapsedHours: 1, reason: .endedEarly) }

    @Test("A result's no-verdict sentence is the one its notice gives") func noVerdictText() {
        #expect(
            ISFTestEvaluator.noVerdictText(.noBolus, test: noBolusTest)
                == "The test needs your bolus within 90 minutes of starting. Trio didn't see one, so there was nothing to judge."
        )
        #expect(ISFTestEvaluator.noVerdictText(.interrupted, test: interrupted) == interrupted.interference)
        #expect(
            ISFTestEvaluator.noVerdictText(.tooSoon, test: endedAfterOneHour)
                == "This test ended after 1 h, so it's too soon to tell what your ISF did."
        )
    }

    @Test("Every other no-verdict sentence is the one the Result gave") func noVerdictTextOthers() {
        let test = finished()
        #expect(
            ISFTestEvaluator.noVerdictText(.interrupted, test: finished(reason: .interrupted))
                == "Something changed during the test, so the result can't be trusted. Try again."
        )
        #expect(ISFTestEvaluator.noVerdictText(.historyUnread, test: test) == ISFTestEvaluator.historyUnreadNote)
        #expect(
            ISFTestEvaluator.noVerdictText(.lowUnchecked, test: test)
                == "Trio couldn't read the pump history to check for a low, so it can't judge this test."
        )
        #expect(
            ISFTestEvaluator.noVerdictText(.noReadings, test: test)
                == "No CGM readings were recorded at the bolus or at the end of the test, so there is nothing to compare."
        )
        #expect(
            ISFTestEvaluator.noVerdictText(.noAmount, test: test)
                == "The pump didn't record how much insulin the bolus gave, so there is no drop per unit to work out."
        )
        #expect(
            ISFTestEvaluator.noVerdictText(.doseTooSmall, test: test)
                == "The dose was too small for this test to tell your ISF apart from CGM noise."
        )
        #expect(
            ISFTestEvaluator.noVerdictText(.forecastSuspend, test: test)
                ==
                "Trio suspended insulin on its forecast while your glucose was still above your target, so the test can't tell."
        )
        #expect(
            ISFTestEvaluator.noVerdictText(.doseOverDocs, test: test)
                == "The bolus was more than the formula's dose, so the low can't be put down to your ISF."
        )
        #expect(ISFTestEvaluator.noVerdictText(nil, test: test) == "Trio couldn't tell what your ISF did from this test.")
    }

    @Test("The time a test ran is from the bolus, or Start if none came, to its end") func elapsedText() {
        // Whole hours, then hours and minutes, then minutes.
        #expect(ISFTestEvaluator.elapsedText(for: finished()) == "4 h")
        #expect(ISFTestEvaluator.elapsedText(for: endedAfterOneHour) == "1 h")
        #expect(ISFTestEvaluator.elapsedText(for: finished(elapsedHours: 2.5)) == "2 h 30 m")
        #expect(ISFTestEvaluator.elapsedText(for: finished(elapsedHours: 0.75)) == "45 m")
        // No bolus: from Start.
        #expect(ISFTestEvaluator.elapsedText(for: noBolusTest) == "1 h 30 m")
        // Not ended: to the planned end with a bolus, to the dose deadline without.
        var running = finished()
        running.endedAt = nil
        #expect(ISFTestEvaluator.elapsedText(for: running) == "4 h")
        var waiting = noBolusTest
        waiting.endedAt = nil
        #expect(ISFTestEvaluator.elapsedText(for: waiting) == "1 h 30 m")
        // Never negative.
        var early = finished()
        early.endedAt = testStart
        #expect(ISFTestEvaluator.elapsedText(for: early) == "0 m")
    }

    @Test("The docs' dose is rounded up to the pump's increment before a low's bolus is held against it") func lowWithPumpRounding() {
        func why(units: Decimal, start: Int, isf: Decimal = 50, increment: Decimal) -> ISFTestNoVerdict? {
            ISFTestEvaluator.lowNoVerdict(
                glucoseAtSuspend: 70,
                startGlucose: start,
                givenUnits: units,
                target: 100,
                isf: isf,
                increment: increment
            )
        }
        #expect(ISFTestEvaluator.roundedUp(dec("0.47"), to: dec("0.05")) == dec("0.5"))
        #expect(ISFTestEvaluator.roundedUp(dec("0.5"), to: dec("0.05")) == dec("0.5"))
        #expect(ISFTestEvaluator.roundedUp(dec("0.47"), to: 0) == dec("0.47"))
        // The docs' 0.47 U ((147 − 100) ÷ 100), which a 0.05 U pump gives as 0.50 U: the low keeps its verdict.
        // Unrounded, 0.50 U is more than a step over 0.47 U, and it wouldn't.
        #expect(why(units: dec("0.5"), start: 147, isf: 100, increment: dec("0.05")) == nil)
        #expect(why(units: dec("0.5"), start: 147, isf: 100, increment: 0) == .doseOverDocs)
        // More than a step over the rounded-up dose still has no verdict.
        #expect(why(units: dec("0.55"), start: 147, isf: 100, increment: dec("0.05")) == .doseOverDocs)
        // A finished test uses the increment saved at Begin: the docs' 0.46 U from 123, given as 0.50 U.
        var low = finished(start: 123, end: 70, units: dec("0.5"), elapsedHours: 1, reason: .low)
        #expect(ISFTestEvaluator.noVerdict(for: low) == .doseOverDocs)
        low.bolusIncrement = dec("0.05")
        #expect(ISFTestEvaluator.noVerdict(for: low) == nil)
        #expect(ISFTestEvaluator.evaluation(of: low)?.outcome == .tooLow)
    }

    @Test(
        "A mode change the service's end put back says the usual mode is back; one left alone keeps the plain words"
    ) func modeChangedAndPutBack() {
        func record(_ restored: Bool?, after seconds: TimeInterval) -> SettingsTestEnd {
            SettingsTestEnd(sessionID: testSession, cause: .modeChanged, date: at(seconds), modeRestored: restored)
        }
        #expect(check(.dosing, ended: record(true, after: 900), now: 960, mode: .closed) == .modeChangedRestored)
        #expect(check(.settling, ended: record(true, after: 300), now: 360, mode: .closed) == .modeChangedRestored)
        #expect(check(.waiting, ended: record(true, after: 3600), now: 3660, mode: .closed) == .modeChangedRestored)
        #expect(check(.dosing, ended: record(false, after: 900), now: 960, mode: .closed) == .modeChanged)
        #expect(check(.waiting, ended: record(nil, after: 3600), now: 3660, mode: .closed) == .modeChanged)
        #expect(ISFTestEvaluator.decidable(.modeChangedRestored, bolusesRead: false) == .modeChangedRestored)
        let ending = ISFTestEvaluator.ending(for: .modeChangedRestored, doseDeadline: doseDeadline)
        #expect(ending == ISFTestEvaluator.Ending(
            reason: .interrupted,
            at: nil,
            note: "The dosing mode changed during the test, so it has no result. Your usual dosing mode is back."
        ))
        // The basal fast reads it the same way.
        #expect(BasalTestEvaluator.runningCheck(
            sessionID: testSession,
            serviceEnd: record(true, after: 900),
            suspend: .none,
            now: at(960),
            plannedEnd: at(4 * hour),
            mode: .closed
        ) == .modeChangedRestored)
        #expect(BasalTestEvaluator.runningCheck(
            sessionID: testSession,
            serviceEnd: record(false, after: 900),
            suspend: .none,
            now: at(960),
            plannedEnd: at(4 * hour),
            mode: .closed
        ) == .modeChanged)
    }

    @Test("Every end path puts the usual mode back while Basal Testing is on, and leaves any other mode") func modeRule() {
        let action = SettingsTestRestoreAction.dosingMode(testMode: .basalTesting, previous: .closed)
        #expect(action.modeToRestore(current: .basalTesting) == .closed)
        #expect(action.modeToRestore(current: .closed) == nil)
        #expect(action.modeToRestore(current: .lowGlucoseSuspend) == nil)
        #expect(action.modeToRestore(current: .open) == nil)
        #expect(
            SettingsTestRestoreAction.dosingMode(testMode: .basalTesting, previous: .basalTesting)
                .modeToRestore(current: .basalTesting) == nil
        )
    }

    // MARK: Visual fixes after the render of the screens

    /// Tablets, then a suspend: glucose at the suspend is `end`, against a target of 100, from 212 on 2.24 U.
    private func suspended(at end: Int) -> ISFTestState {
        finished(end: end, elapsedHours: 1, reason: .low)
    }

    @Test("A forecast suspend shows no low card and says it ended on the forecast") func forecastSuspendCaption() {
        let forecast = suspended(at: 140)
        let realLow = suspended(at: 68)
        #expect(ISFTestEvaluator.noVerdict(for: forecast) == .forecastSuspend)
        #expect(!ISFTestEvaluator.showsLowCard(for: forecast))
        #expect(
            ISFTestEvaluator.endedEarlyCaption(for: forecast) == ". Ended early: Trio suspended insulin on its forecast."
        )
        #expect(ISFTestEvaluator.noVerdict(for: realLow) == nil)
        #expect(ISFTestEvaluator.showsLowCard(for: realLow))
        #expect(ISFTestEvaluator.endedEarlyCaption(for: realLow) == ". Ended early: Trio suspended insulin for a low.")
        // Glucose at the target is a low that is one; just above it, the forecast's.
        #expect(ISFTestEvaluator.showsLowCard(for: suspended(at: 100)))
        #expect(!ISFTestEvaluator.showsLowCard(for: suspended(at: 101)))
        // A low after more than the docs' dose is still a low to treat, with no verdict on the ISF.
        let overDocs = finished(end: 60, units: 5, elapsedHours: 1, reason: .low)
        #expect(ISFTestEvaluator.noVerdict(for: overDocs) == .doseOverDocs)
        #expect(ISFTestEvaluator.showsLowCard(for: overDocs))
        #expect(ISFTestEvaluator.endedEarlyCaption(for: overDocs) == ". Ended early: Trio suspended insulin for a low.")
    }

    @Test("Only a low gets the low card, and the other end reasons keep their captions") func captionsPerEndReason() {
        #expect(!ISFTestEvaluator.showsLowCard(for: finished()))
        #expect(!ISFTestEvaluator.showsLowCard(for: endedAfterOneHour))
        #expect(!ISFTestEvaluator.showsLowCard(for: interrupted))
        #expect(ISFTestEvaluator.endedEarlyCaption(for: finished()) == "")
        #expect(ISFTestEvaluator.endedEarlyCaption(for: endedAfterOneHour) == ". You ended it early.")
        #expect(ISFTestEvaluator.endedEarlyCaption(for: interrupted) == ". Ended early: it was interrupted.")
        #expect(ISFTestEvaluator.endedEarlyCaption(for: finished(reason: .unchecked)) == "")
        #expect(ISFTestEvaluator.endedEarlyCaption(for: noBolusTest) == "")
        // A test with no end reason yet has no caption to give.
        var running = finished()
        running.endReason = nil
        running.endedAt = nil
        #expect(!ISFTestEvaluator.showsLowCard(for: running))
        #expect(ISFTestEvaluator.endedEarlyCaption(for: running) == "")
    }

    @Test("A forecast suspend is a suspend on the forecast above the target, and nothing else") func forecastSuspendPredicate() {
        #expect(ISFTestEvaluator.isForecastSuspend(for: suspended(at: 140)))
        #expect(ISFTestEvaluator.isForecastSuspend(for: suspended(at: 101)))
        #expect(!ISFTestEvaluator.isForecastSuspend(for: suspended(at: 100)))
        #expect(!ISFTestEvaluator.isForecastSuspend(for: suspended(at: 68)))
        // Other end reasons with glucose above the target aren't a suspend at all.
        #expect(!ISFTestEvaluator.isForecastSuspend(for: finished(end: 140, elapsedHours: 1, reason: .endedEarly)))
        #expect(!ISFTestEvaluator.isForecastSuspend(for: finished(end: 140)))
        #expect(!ISFTestEvaluator.isForecastSuspend(for: interrupted))
        // An interrupted low, and a low after too big a dose, are lows to treat, not forecasts.
        let interruptedLow = finished(end: 140, elapsedHours: 1, reason: .low, interference: "Carbs were logged during the test.")
        #expect(!ISFTestEvaluator.isForecastSuspend(for: interruptedLow))
        #expect(!ISFTestEvaluator.isForecastSuspend(for: finished(end: 60, units: 5, elapsedHours: 1, reason: .low)))
        // The low card and the caption follow it.
        for test in [suspended(at: 140), suspended(at: 100), suspended(at: 68), interruptedLow, endedAfterOneHour] {
            #expect(
                ISFTestEvaluator
                    .showsLowCard(for: test) == (test.endReason == .low && !ISFTestEvaluator.isForecastSuspend(for: test))
            )
        }
    }

    @Test(
        "The header says a low only for a low: a forecast suspend gets the lines of a test with no verdict"
    ) func suspendHeaderLine() {
        let realLow = suspended(at: 68)
        let time = realLow.endedAt!.formatted(date: .omitted, time: .shortened)
        #expect(ISFTestEvaluator.lowSuspendObservation(for: realLow) == "Trio suspended insulin for a low at \(time)")
        // A low after too big a dose and an interrupted low are still lows.
        #expect(
            ISFTestEvaluator.lowSuspendObservation(for: finished(end: 60, units: 5, elapsedHours: 1, reason: .low))
                == "Trio suspended insulin for a low at \(time)"
        )
        let forecast = suspended(at: 140)
        #expect(ISFTestEvaluator.lowSuspendObservation(for: forecast) == nil)
        // The header's next lines: a test with no verdict isn't conclusive, so it reads "Ended after ...".
        #expect(forecast.outcome == .inconclusive)
        #expect(forecast.outcome?.isConclusive == false)
        #expect(ISFTestEvaluator.elapsedText(for: forecast) == "1 h")
        // Other end reasons, and a low with no end time, have no suspend line.
        #expect(ISFTestEvaluator.lowSuspendObservation(for: finished()) == nil)
        #expect(ISFTestEvaluator.lowSuspendObservation(for: endedAfterOneHour) == nil)
        #expect(ISFTestEvaluator.lowSuspendObservation(for: interrupted) == nil)
        var noEnd = realLow
        noEnd.endedAt = nil
        #expect(ISFTestEvaluator.lowSuspendObservation(for: noEnd) == nil)
    }

    @Test("Only a Dose step with a way on shows the bolus deadline") func doseDeadlineShown() {
        // A dose, or a reading still to come.
        #expect(ISFTestEvaluator.showsDoseDeadline(noDose: nil, canRaise: false))
        #expect(ISFTestEvaluator.showsDoseDeadline(noDose: nil, canRaise: true))
        #expect(ISFTestEvaluator.showsDoseDeadline(noDose: .carbsUnread, canRaise: false))
        #expect(ISFTestEvaluator.showsDoseDeadline(noDose: .noRecentReading, canRaise: false))
        #expect(ISFTestEvaluator.showsDoseDeadline(noDose: .iobUnread, canRaise: false))
        // At or below the target, only with Take Glucose Tablets to offer.
        #expect(ISFTestEvaluator.showsDoseDeadline(noDose: .atOrBelowTarget, canRaise: true))
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .atOrBelowTarget, canRaise: false))
        // Cancel-only dead ends.
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .carbsOnBoard, canRaise: true))
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .carbsOnBoard, canRaise: false))
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .iobCoversDose, canRaise: true))
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .iobCoversDose, canRaise: false))
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .noSettings, canRaise: true))
        #expect(!ISFTestEvaluator.showsDoseDeadline(noDose: .noSettings, canRaise: false))
    }

    @Test("The deadline shows exactly when the Dose footer offers a way on, for every reason") func doseDeadlineMatchesFooter() {
        let every: [ISFTestNoDose] = [
            .carbsOnBoard, .carbsUnread, .noRecentReading, .atOrBelowTarget, .noSettings, .iobCoversDose, .iobUnread
        ]
        for noDose in every {
            for canRaise in [true, false] {
                // The footer: Open Treatments turned off while waiting for a reading, Take Glucose Tablets at or below the
                // target when tablets can be offered, and otherwise only Cancel Test.
                let footerOffersWayOn = noDose.isWaiting || (noDose == .atOrBelowTarget && canRaise)
                #expect(ISFTestEvaluator.showsDoseDeadline(noDose: noDose, canRaise: canRaise) == footerOffersWayOn)
            }
        }
    }

    @Test("The parts of the test's hours start and end on the entries' edges, as the hours do") func coveredSpansEdges() {
        let schedule = [entry(0, 486, 50), entry(486, 1440, 40)]
        // Starting exactly where an entry starts, the entry before isn't listed.
        #expect(
            ISFTestEvaluator.coveredSpans(schedule, from: time(8, 6), for: 4 * hour, calendar: utc) == [entry(486, 726, 40)]
        )
        // Ending exactly where the next starts, it isn't listed.
        #expect(
            ISFTestEvaluator.coveredSpans(schedule, from: time(4, 6), for: 4 * hour, calendar: utc) == [entry(246, 486, 50)]
        )
        // Ending at midnight: the last part runs to the end of the day and nothing of the next.
        #expect(
            ISFTestEvaluator.coveredSpans(schedule, from: time(20), for: 4 * hour, calendar: utc) == [entry(1200, 1440, 40)]
        )
        // One entry that doesn't wrap: the hours from the start, not the whole day.
        #expect(
            ISFTestEvaluator.coveredSpans([entry(0, 1440, 50)], from: time(6, 30), for: 4 * hour, calendar: utc)
                == [entry(390, 630, 50)]
        )
        // A part that is the whole entry.
        #expect(
            ISFTestEvaluator.coveredSpans(schedule, from: time(8, 6), for: 2 * hour, calendar: utc) == [entry(486, 606, 40)]
        )
    }

    @Test("The ISF-change sheet lists the test's 4 hours split by ISF, in the user's units") func isfChangeReading() {
        let britain = SettingsTestSchedule.makeTimeFormatter(locale: Locale(identifier: "en_GB"))
        // 0:00-8:06 at 50, 8:06-24:00 at 40, from 6:30: the 4 hours end at 10:30, not at the end of the second entry.
        let schedule = [entry(0, 486, 50), entry(486, 1440, 40)]
        let spans = ISFTestEvaluator.coveredSpans(schedule, from: time(6, 30), for: 4 * hour, calendar: utc)
        #expect(spans.map(\.startMinutes) == [390, 486])
        #expect(spans.map(\.endMinutes) == [486, 630])
        #expect(spans.map(\.value) == [50, 40])
        // What a reader sees (the no-break spaces and word joiners that keep a part on one line aside).
        #expect(
            visible(ISFTestEvaluator.isfChangeReading(spans, units: .mgdL, formatter: britain))
                == visible(
                    "06:30–08:06: \(SettingsTestKind.isfText(50, units: .mgdL)), 08:06–10:30: \(SettingsTestKind.isfText(40, units: .mgdL))"
                )
        )
        // In mmol/L the numbers are the user's, with their unit.
        let mmol = ISFTestEvaluator.isfChangeReading(spans, units: .mmolL, formatter: britain)
        #expect(
            visible(mmol)
                == visible(
                    "06:30–08:06: \(SettingsTestKind.isfText(50, units: .mmolL)), 08:06–10:30: \(SettingsTestKind.isfText(40, units: .mmolL))"
                )
        )
        #expect(mmol != ISFTestEvaluator.isfChangeReading(spans, units: .mgdL, formatter: britain))
        // Across midnight: from 22:00, the end of the day, then the start of the next.
        let nightSchedule = [entry(0, 60, 40), entry(60, 1320, 45), entry(1320, 1440, 50)]
        let night = ISFTestEvaluator.coveredSpans(nightSchedule, from: time(22), for: 4 * hour, calendar: utc)
        #expect(night.map(\.value) == [50, 40, 45])
        #expect(night == [entry(1320, 1440, 50), entry(0, 60, 40), entry(60, 120, 45)])
        // Adjacent entries with the same ISF are one part.
        let split = [entry(0, 300, 50), entry(300, 420, 50), entry(420, 1440, 40)]
        #expect(
            ISFTestEvaluator.coveredSpans(split, from: time(4), for: 4 * hour, calendar: utc)
                == [entry(240, 420, 50), entry(420, 480, 40)]
        )
        // One ISF all day, from 22:00, is one part across midnight.
        let allDay = ISFTestEvaluator.coveredSpans([entry(0, 1440, 50)], from: time(22), for: 4 * hour, calendar: utc)
        #expect(allDay == [entry(1320, 120, 50)])
        #expect(
            visible(ISFTestEvaluator.isfChangeReading(allDay, units: .mgdL, formatter: britain))
                == visible("22:00–02:00: \(SettingsTestKind.isfText(50, units: .mgdL))")
        )
        // Nothing to list without a schedule or hours.
        #expect(ISFTestEvaluator.coveredSpans([], from: time(6, 30), for: 4 * hour, calendar: utc).isEmpty)
        #expect(ISFTestEvaluator.coveredSpans(schedule, from: time(6, 30), for: 0, calendar: utc).isEmpty)
        #expect(ISFTestEvaluator.isfChangeReading([], units: .mgdL, formatter: britain) == "")
    }

    /// The characters a reader sees: no-break spaces as spaces, word joiners gone.
    private func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2060}", with: "")
    }

    private var subheadline: [NSAttributedString.Key: Any] { [.font: UIFont.preferredFont(forTextStyle: .subheadline)] }

    /// The width of the wider of two parts, the first with its comma, with a point to spare.
    private func partWidth(_ parts: [String]) -> Double {
        [parts[0] + ",", parts[1]].map { part -> Double in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: part, attributes: subheadline))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }.max()! + 1
    }

    /// The lines CoreText breaks `text` into at `width`, without the spaces a break leaves at a line's end.
    private func typeset(_ text: String, width: Double) -> [String] {
        let attributed = NSAttributedString(string: text, attributes: subheadline)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let whole = text as NSString
        var lines: [String] = []
        var start = 0
        while start < whole.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, width)
            lines.append(whole.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespaces))
            start += count
        }
        return lines
    }

    @Test("The ISF-change sheet can only break between its parts, in 24-hour and 12-hour locales") func isfChangeReadingBreaks() {
        let schedule = [entry(0, 486, 50), entry(486, 1440, 40)]
        let spans = ISFTestEvaluator.coveredSpans(schedule, from: time(6, 30), for: 4 * hour, calendar: utc)
        for locale in ["en_GB", "en_US", "de_DE", "es_ES"] {
            let formatter = SettingsTestSchedule.makeTimeFormatter(locale: Locale(identifier: locale))
            for units in [GlucoseUnits.mgdL, .mmolL] {
                let reading = ISFTestEvaluator.isfChangeReading(spans, units: units, formatter: formatter)
                // The parts are joined by a comma and a plain space, and nothing else in the text is a plain space.
                let parts = reading.components(separatedBy: ", ")
                #expect(parts.count == 2, "\(locale) \(units)")
                for part in parts {
                    #expect(!part.contains(" "), "a plain space in \(part.debugDescription) (\(locale) \(units))")
                    // The hours, a colon and the ISF with its unit: the no-break space after the colon, and the dash
                    // followed by a word joiner.
                    #expect(part.contains(":\u{00A0}"), "\(part.debugDescription)")
                    #expect(part.contains("–\u{2060}"), "\(part.debugDescription)")
                }
                // The ISF of each part is the one in the user's units, as it is shown elsewhere.
                #expect(parts[0].hasSuffix(SettingsTestKind.isfText(50, units: units)))
                #expect(parts[1].hasSuffix(SettingsTestKind.isfText(40, units: units)))
                // And in the sheet's sentence, typeset in a width that holds either part but not the lead-in with the first
                // one, the first part moves to the next line whole, rather than breaking inside it.
                let lead = "These hours cover"
                #expect(
                    typeset("\(lead) \(reading)", width: partWidth(parts)) == [lead, parts[0] + ",", parts[1]],
                    "\(reading.debugDescription) (\(locale) \(units))"
                )
            }
        }
    }

    @Test("Raise before the tablets acted says so in the card title") func levelingTitle() {
        #expect(ISFTestEvaluator.levelingTitle(phase: .raising, tabletsActed: false) == "Waiting for the tablets to act")
        #expect(ISFTestEvaluator.levelingTitle(phase: .raising, tabletsActed: true) == "Waiting for your glucose to level off")
        #expect(ISFTestEvaluator.levelingTitle(phase: .dosing, tabletsActed: false) == "Waiting for your glucose to level off")
        #expect(ISFTestEvaluator.levelingTitle(phase: .dosing, tabletsActed: true) == "Waiting for your glucose to level off")
    }
}

/// A copy of the Dose step's inputs with one part changed, for the tests that vary one at a time. Each takes the plain
/// optional, so `nil` sets the part to nothing.
extension ISFTestDoseInputs {
    func with(direction: BloodGlucose.Direction?) -> ISFTestDoseInputs {
        var copy = self
        copy.direction = direction
        return copy
    }

    func with(iob: Decimal?) -> ISFTestDoseInputs {
        var copy = self
        copy.iob = iob
        return copy
    }

    func with(doseIOB: Decimal?) -> ISFTestDoseInputs {
        var copy = self
        copy.doseIOB = doseIOB
        return copy
    }

    func with(cob: Decimal?) -> ISFTestDoseInputs {
        var copy = self
        copy.cob = cob
        return copy
    }

    func with(readings: [BasalTestReading]) -> ISFTestDoseInputs {
        var copy = self
        copy.readings = readings
        return copy
    }

    /// The readings moved together so the newest is `age` seconds before `now`, spacing kept.
    func with(newestAgo age: TimeInterval) -> ISFTestDoseInputs {
        guard let newest = readings.first?.date else { return self }
        let shift = now.addingTimeInterval(-age).timeIntervalSince(newest)
        var copy = self
        copy.readings = readings.map { BasalTestReading(date: $0.date.addingTimeInterval(shift), glucose: $0.glucose) }
        return copy
    }
}
