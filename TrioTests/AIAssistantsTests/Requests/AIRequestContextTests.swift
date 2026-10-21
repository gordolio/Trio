import Foundation
import Testing

@testable import Trio

/// Why Trio's dose is 0 U, which the request's notification says when Trio knows the reason is true.
@Suite("AI request no-dose reason") struct AIRequestContextTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func reading(
        mgdl: Int = 142,
        minutesAgo: Double = 3,
        direction: String? = "FortyFiveUp"
    ) -> StatusSnapshot.LatestGlucose {
        .init(date: now - minutesAgo * 60, mgdl: mgdl, direction: direction, deltaMgdl: nil)
    }

    /// The reason for a dose of `units`, a minute-old loop run, a forecast that's fine and no determination, so no
    /// insulin on board, unless said otherwise.
    private func make(
        glucose: StatusSnapshot.LatestGlucose? = nil,
        loopMinutesAgo: Double = 1,
        minPredBG: Decimal = 100,
        iob: Decimal? = nil,
        maxIOB: Decimal = 5,
        displayUnits: String = "mg/dL",
        units: Decimal = 1.2
    ) -> String? {
        BaseAIRequestTreatments.noDoseReason(
            glucose: glucose,
            lastLoopDate: now - loopMinutesAgo * 60,
            minPredBG: minPredBG,
            iob: iob,
            maxIOB: maxIOB,
            displayUnits: displayUnits,
            units: units,
            now: now
        )
    }

    // MARK: Why the dose is 0 U

    @Test func thereIsNoReasonWhileTheDoseIsNotZero() {
        let reason = make(glucose: reading(mgdl: 40), loopMinutesAgo: 40, minPredBG: 30, units: 0.05)
        #expect(reason == nil)
    }

    @Test func lowGlucoseIsTheFirstReason() {
        // Every reason applies, and glucose comes first.
        let reason = make(glucose: reading(mgdl: 52), loopMinutesAgo: 40, minPredBG: 30, units: 0)
        #expect(reason == "glucose is low (52 mg/dL)")
        let mmol = make(glucose: reading(mgdl: 52), minPredBG: 30, displayUnits: "mmol/L", units: 0)
        #expect(mmol == "glucose is low (2.9 mmol/L)")
    }

    @Test func aForecastUnderTheLimitIsTheSecondReason() {
        let reason = make(glucose: reading(mgdl: 120), loopMinutesAgo: 40, minPredBG: 53, units: 0)
        #expect(reason == "glucose is forecast to go low")
    }

    @Test func aStaleLoopIsTheThirdReason() {
        let reason = make(glucose: reading(mgdl: 120), loopMinutesAgo: 22.5, minPredBG: 100, units: 0)
        #expect(reason == "the loop hasn't run for 22 min")
    }

    @Test func noReadingIsTheFourthReason() {
        let reason = make(glucose: nil, units: 0)
        #expect(reason == "there's no recent glucose reading")
        // It comes after a forecast low and a stale loop, and before insulin on board.
        #expect(make(glucose: nil, minPredBG: 30, iob: 9, units: 0) == "glucose is forecast to go low")
        #expect(make(glucose: nil, loopMinutesAgo: 20, iob: 9, units: 0) == "the loop hasn't run for 20 min")
        #expect(make(glucose: nil, iob: 9, units: 0) == "there's no recent glucose reading")
    }

    @Test func insulinOnBoardAtItsMaxIsTheFifthReason() {
        let steady = reading(mgdl: 120)
        // At the max is the boundary: the calculator allows max less insulin on board, which is nothing.
        #expect(make(glucose: steady, iob: 5, maxIOB: 5, units: 0) == "insulin on board is at your max")
        #expect(make(glucose: steady, iob: 5.01, maxIOB: 5, units: 0) == "insulin on board is at your max")
        #expect(make(glucose: steady, iob: 7, maxIOB: 5, units: 0) == "insulin on board is at your max")
        // A max of 0 with no insulin on board leaves nothing to give either.
        #expect(make(glucose: steady, iob: 0, maxIOB: 0, units: 0) == "insulin on board is at your max")
        // Every earlier reason comes first.
        #expect(make(glucose: reading(mgdl: 52), iob: 9, maxIOB: 5, units: 0) == "glucose is low (52 mg/dL)")
        #expect(make(glucose: steady, minPredBG: 30, iob: 9, maxIOB: 5, units: 0) == "glucose is forecast to go low")
        #expect(
            make(glucose: steady, loopMinutesAgo: 20, iob: 9, maxIOB: 5, units: 0)
                == "the loop hasn't run for 20 min"
        )
    }

    @Test func noReasonIsGivenWhenTrioDoesNotKnowOne() {
        let steady = reading(mgdl: 120)
        // Insulin on board under the max: the dose can still be 0 U because it works out to 0, or to less than one
        // increment of the pump, and neither is worth a made-up reason.
        #expect(make(glucose: steady, iob: 4.99, maxIOB: 5, units: 0) == nil)
        #expect(make(glucose: steady, iob: 0, maxIOB: 5, units: 0) == nil)
        // No determination from the last 30 minutes means no insulin on board to compare.
        #expect(make(glucose: steady, iob: nil, maxIOB: 0, units: 0) == nil)
        #expect(make(glucose: steady, units: 0) == nil)
    }

    @Test func theLimitsAreTheBolusCalculatorsOwn() {
        // 54 mg/dL is not low, and 15 min is not stale: the calculator uses < 54 and > 15 min.
        #expect(make(glucose: reading(mgdl: 54), loopMinutesAgo: 15, minPredBG: 54, units: 0) == nil)
        #expect(make(glucose: reading(mgdl: 53), units: 0) == "glucose is low (53 mg/dL)")
        #expect(make(glucose: reading(mgdl: 54), minPredBG: 53.9, units: 0) == "glucose is forecast to go low")
        #expect(make(loopMinutesAgo: 15.1, units: 0) == "the loop hasn't run for 15 min")
        #expect(BaseAIRequestTreatments.lowGlucoseMgdl == 54)
        #expect(BaseAIRequestTreatments.staleLoopAge == 15 * 60)
    }

    @Test func aLoopThatNeverRanIsStaleForADay() {
        // A loop that never ran has no date, so its age is capped at a day rather than the age of the distant past.
        let reason = BaseAIRequestTreatments.noDoseReason(
            glucose: reading(mgdl: 120),
            lastLoopDate: .distantPast,
            minPredBG: 100,
            iob: nil,
            maxIOB: 5,
            displayUnits: "mg/dL",
            units: 0,
            now: now
        )
        #expect(reason == "the loop hasn't run for 1440 min")
    }
}
