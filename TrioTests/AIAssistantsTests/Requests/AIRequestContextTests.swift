import Foundation
import Testing

@testable import Trio

/// The facts Trio sends with a request. trio-rc refuses the whole pending report if one value is outside its limits,
/// and the request then never reaches the watch, so each of these stays inside them.
@Suite("AI request context") struct AIRequestContextTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func reading(
        mgdl: Int = 142,
        minutesAgo: Double = 3,
        direction: String? = "FortyFiveUp"
    ) -> StatusSnapshot.LatestGlucose {
        .init(date: now - minutesAgo * 60, mgdl: mgdl, direction: direction, deltaMgdl: nil)
    }

    private func carbs(_ grams: Double, minutesAgo: Double) -> StatusSnapshot.Treatment {
        .carbs(date: now - minutesAgo * 60, carbs: grams, fat: nil, protein: nil, note: nil)
    }

    private func bolus(_ units: Double, minutesAgo: Double, smb: Bool = false) -> StatusSnapshot.Treatment {
        .bolus(date: now - minutesAgo * 60, units: units, isSMB: smb, isExternal: false)
    }

    /// The context for a dose of `units`, a minute-old loop run, a forecast that's fine and no determination, so no
    /// insulin on board, unless said otherwise.
    private func make(
        glucose: StatusSnapshot.LatestGlucose? = nil,
        treatments: [StatusSnapshot.Treatment] = [],
        loopMinutesAgo: Double = 1,
        minPredBG: Decimal = 100,
        iob: Decimal? = nil,
        maxIOB: Decimal = 5,
        displayUnits: String = "mg/dL",
        units: Decimal = 1.2
    ) -> AIRequestContext {
        BaseAIRequestTreatments.context(
            glucose: glucose,
            recentTreatments: treatments,
            lastLoopDate: now - loopMinutesAgo * 60,
            minPredBG: minPredBG,
            iob: iob,
            maxIOB: maxIOB,
            displayUnits: displayUnits,
            units: units,
            now: now
        )
    }

    // MARK: Glucose

    @Test func glucoseHasItsTrendAndAge() {
        let context = make(glucose: reading(minutesAgo: 3.9))
        #expect(context.glucose == "142 mg/dL ↗")
        #expect(context.glucoseAgeMinutes == 3)
    }

    @Test func glucoseFollowsTheDisplayUnits() {
        #expect(make(glucose: reading(mgdl: 142), displayUnits: "mmol/L").glucose == "7.9 mmol/L ↗")
        // 126 mg/dL is 6.993 mmol/L, which keeps its decimal as 7.0.
        #expect(make(glucose: reading(mgdl: 126, direction: nil), displayUnits: "mmol/L").glucose == "7.0 mmol/L")
        #expect(make(glucose: reading(mgdl: 126, direction: "Flat"), displayUnits: "mg/dL").glucose == "126 mg/dL →")
    }

    @Test func noReadingGivesNoGlucose() {
        let context = make(glucose: nil)
        #expect(context.glucose == nil && context.glucoseAgeMinutes == nil)
    }

    @Test func aReadingDatedInTheFutureHasNoAge() {
        // A sensor clock a little ahead of the phone's: the reading is still shown, but it has no age.
        let context = make(glucose: reading(minutesAgo: -2))
        #expect(context.glucose == "142 mg/dL ↗")
        #expect(context.glucoseAgeMinutes == nil)
    }

    @Test func aReadingOlderThanADayIsLeftOut() {
        let atTheLimit = make(glucose: reading(minutesAgo: 1440))
        #expect(atTheLimit.glucose != nil && atTheLimit.glucoseAgeMinutes == 1440)
        let past = make(glucose: reading(minutesAgo: 1440.5))
        #expect(past.glucose == nil && past.glucoseAgeMinutes == nil)
        let twoDays = make(glucose: reading(minutesAgo: 2 * 1440))
        #expect(twoDays.glucose == nil && twoDays.glucoseAgeMinutes == nil)
    }

    // MARK: Recent carbs

    @Test func recentCarbsAreTheNewestEntryWithinFifteenMinutes() {
        let context = make(treatments: [
            carbs(12.5, minutesAgo: 3.5), // newest
            carbs(20, minutesAgo: 12),
            carbs(30, minutesAgo: 400)
        ])
        #expect(context.recentCarbs == .init(amount: "12.5", minutesAgo: 3))
    }

    @Test func recentCarbsDoNotRelyOnTheOrder() {
        let context = make(treatments: [carbs(20, minutesAgo: 12), carbs(12.5, minutesAgo: 3)])
        #expect(context.recentCarbs == .init(amount: "12.5", minutesAgo: 3))
    }

    @Test func recentCarbsAreShownUnderFifteenMinutesOnly() {
        #expect(make(treatments: [carbs(35, minutesAgo: 14.9)]).recentCarbs == .init(amount: "35", minutesAgo: 14))
        #expect(make(treatments: [carbs(35, minutesAgo: 15)]).recentCarbs == nil)
        #expect(make(treatments: [carbs(35, minutesAgo: 16)]).recentCarbs == nil)
    }

    @Test func carbsDatedInTheFutureOrEmptyAreSkipped() {
        // A future entry is a planned one; the real, recent one is shown instead.
        let context = make(treatments: [
            carbs(50, minutesAgo: -5),
            carbs(0, minutesAgo: 1),
            carbs(20, minutesAgo: 6)
        ])
        #expect(context.recentCarbs == .init(amount: "20", minutesAgo: 6))
        #expect(make(treatments: [carbs(50, minutesAgo: -5)]).recentCarbs == nil)
    }

    @Test func carbsAreTrimmedToTheirGrams() {
        #expect(make(treatments: [carbs(35.0, minutesAgo: 1)]).recentCarbs?.amount == "35")
        // Through the text, not the double's binary value.
        #expect(make(treatments: [carbs(12.3, minutesAgo: 1)]).recentCarbs?.amount == "12.3")
        // Two decimals, rounded down.
        #expect(make(treatments: [carbs(12.349, minutesAgo: 1)]).recentCarbs?.amount == "12.34")
        // Less than a hundredth is nothing.
        #expect(make(treatments: [carbs(0.004, minutesAgo: 1)]).recentCarbs == nil)
    }

    // MARK: Recent bolus

    @Test func recentBolusIsTheNewestNonSMBWithinThirtyMinutes() {
        let context = make(treatments: [
            bolus(0.3, minutesAgo: 2, smb: true), // an automatic microbolus, not the wearer's
            bolus(3, minutesAgo: 8.2),
            bolus(1, minutesAgo: 20)
        ])
        #expect(context.recentBolus == .init(amount: "3.00", minutesAgo: 8))
    }

    @Test func recentBolusIsShownUnderThirtyMinutesOnly() {
        #expect(make(treatments: [bolus(2.1, minutesAgo: 29.9)]).recentBolus == .init(amount: "2.10", minutesAgo: 29))
        #expect(make(treatments: [bolus(2.1, minutesAgo: 30)]).recentBolus == nil)
        #expect(make(treatments: [bolus(2.1, minutesAgo: 31)]).recentBolus == nil)
    }

    @Test func microbolusesAndFutureOnesGiveNoRecentBolus() {
        #expect(make(treatments: [bolus(0.3, minutesAgo: 2, smb: true)]).recentBolus == nil)
        #expect(make(treatments: [bolus(2, minutesAgo: -3)]).recentBolus == nil)
        #expect(make(treatments: [bolus(0, minutesAgo: 3)]).recentBolus == nil)
    }

    @Test func bolusUnitsHaveTwoDecimals() {
        #expect(make(treatments: [bolus(0.05, minutesAgo: 1)]).recentBolus?.amount == "0.05")
        #expect(make(treatments: [bolus(12.25, minutesAgo: 1)]).recentBolus?.amount == "12.25")
        #expect(make(treatments: [bolus(0.1 + 0.2, minutesAgo: 1)]).recentBolus?.amount == "0.30")
    }

    @Test func aRecentBolusAndRecentCarbsComeFromTheSameList() {
        let context = make(treatments: [carbs(20, minutesAgo: 6), bolus(3, minutesAgo: 8)])
        #expect(context.recentCarbs == .init(amount: "20", minutesAgo: 6))
        #expect(context.recentBolus == .init(amount: "3.00", minutesAgo: 8))
    }

    // MARK: Why the dose is 0 U

    @Test func thereIsNoReasonWhileTheDoseIsNotZero() {
        let context = make(glucose: reading(mgdl: 40), loopMinutesAgo: 40, minPredBG: 30, units: 0.05)
        #expect(context.noDoseReason == nil)
    }

    @Test func lowGlucoseIsTheFirstReason() {
        // Every reason applies, and glucose comes first.
        let context = make(glucose: reading(mgdl: 52), loopMinutesAgo: 40, minPredBG: 30, units: 0)
        #expect(context.noDoseReason == "glucose is low (52 mg/dL)")
        let mmol = make(glucose: reading(mgdl: 52), minPredBG: 30, displayUnits: "mmol/L", units: 0)
        #expect(mmol.noDoseReason == "glucose is low (2.9 mmol/L)")
    }

    @Test func aForecastUnderTheLimitIsTheSecondReason() {
        let context = make(glucose: reading(mgdl: 120), loopMinutesAgo: 40, minPredBG: 53, units: 0)
        #expect(context.noDoseReason == "glucose is forecast to go low")
    }

    @Test func aStaleLoopIsTheThirdReason() {
        let context = make(glucose: reading(mgdl: 120), loopMinutesAgo: 22.5, minPredBG: 100, units: 0)
        #expect(context.noDoseReason == "the loop hasn't run for 22 min")
    }

    @Test func noReadingIsTheFourthReason() {
        let context = make(glucose: nil, units: 0)
        #expect(context.noDoseReason == "there's no recent glucose reading")
        // A reading Trio couldn't read is the same as none: the context gets no reading either way.
        #expect(context.glucose == nil)
        // It comes after a forecast low and a stale loop, and before insulin on board.
        #expect(make(glucose: nil, minPredBG: 30, iob: 9, units: 0).noDoseReason == "glucose is forecast to go low")
        #expect(make(glucose: nil, loopMinutesAgo: 20, iob: 9, units: 0).noDoseReason == "the loop hasn't run for 20 min")
        #expect(make(glucose: nil, iob: 9, units: 0).noDoseReason == "there's no recent glucose reading")
    }

    @Test func insulinOnBoardAtItsMaxIsTheFifthReason() {
        let steady = reading(mgdl: 120)
        // At the max is the boundary: the calculator allows max less insulin on board, which is nothing.
        #expect(make(glucose: steady, iob: 5, maxIOB: 5, units: 0).noDoseReason == "insulin on board is at your max")
        #expect(make(glucose: steady, iob: 5.01, maxIOB: 5, units: 0).noDoseReason == "insulin on board is at your max")
        #expect(make(glucose: steady, iob: 7, maxIOB: 5, units: 0).noDoseReason == "insulin on board is at your max")
        // A max of 0 with no insulin on board leaves nothing to give either.
        #expect(make(glucose: steady, iob: 0, maxIOB: 0, units: 0).noDoseReason == "insulin on board is at your max")
        // Every earlier reason comes first.
        #expect(make(glucose: reading(mgdl: 52), iob: 9, maxIOB: 5, units: 0).noDoseReason == "glucose is low (52 mg/dL)")
        #expect(make(glucose: steady, minPredBG: 30, iob: 9, maxIOB: 5, units: 0).noDoseReason == "glucose is forecast to go low")
        #expect(
            make(glucose: steady, loopMinutesAgo: 20, iob: 9, maxIOB: 5, units: 0).noDoseReason
                == "the loop hasn't run for 20 min"
        )
    }

    @Test func noReasonIsGivenWhenTrioDoesNotKnowOne() {
        let steady = reading(mgdl: 120)
        // Insulin on board under the max: the dose can still be 0 U because it works out to 0, or to less than one
        // increment of the pump, and neither is worth a made-up reason.
        #expect(make(glucose: steady, iob: 4.99, maxIOB: 5, units: 0).noDoseReason == nil)
        #expect(make(glucose: steady, iob: 0, maxIOB: 5, units: 0).noDoseReason == nil)
        // No determination from the last 30 minutes means no insulin on board to compare.
        #expect(make(glucose: steady, iob: nil, maxIOB: 0, units: 0).noDoseReason == nil)
        #expect(make(glucose: steady, units: 0).noDoseReason == nil)
    }

    @Test func theLimitsAreTheBolusCalculatorsOwn() {
        // 54 mg/dL is not low, and 15 min is not stale: the calculator uses < 54 and > 15 min.
        #expect(make(glucose: reading(mgdl: 54), loopMinutesAgo: 15, minPredBG: 54, units: 0).noDoseReason == nil)
        #expect(make(glucose: reading(mgdl: 53), units: 0).noDoseReason == "glucose is low (53 mg/dL)")
        #expect(make(glucose: reading(mgdl: 54), minPredBG: 53.9, units: 0).noDoseReason == "glucose is forecast to go low")
        #expect(make(loopMinutesAgo: 15.1, units: 0).noDoseReason == "the loop hasn't run for 15 min")
        #expect(BaseAIRequestTreatments.lowGlucoseMgdl == 54)
        #expect(BaseAIRequestTreatments.staleLoopAge == 15 * 60)
    }

    @Test func aLoopThatNeverRanIsStaleForAsLongAsTheServiceTakes() {
        let context = BaseAIRequestTreatments.context(
            glucose: reading(mgdl: 120),
            recentTreatments: [],
            lastLoopDate: .distantPast,
            minPredBG: 100,
            iob: nil,
            maxIOB: 5,
            displayUnits: "mg/dL",
            units: 0,
            now: now
        )
        #expect(context.noDoseReason == "the loop hasn't run for 1440 min")
    }

    // MARK: Limits

    @Test func contextStaysWithinTheServiceLimits() {
        let hostile = make(
            glucose: reading(minutesAgo: -2),
            treatments: [
                carbs(1E20, minutesAgo: 1),
                bolus(1E20, minutesAgo: 1),
                carbs(20, minutesAgo: 2000),
                bolus(2, minutesAgo: 2000)
            ],
            loopMinutesAgo: 100_000,
            minPredBG: 10,
            units: 0
        )
        // The future reading has no age; carbs and a bolus 2,000 minutes old are left out; amounts too long to send
        // are left out rather than cut into a different number.
        #expect(hostile.glucoseAgeMinutes == nil)
        #expect(hostile.recentCarbs == nil && hostile.recentBolus == nil)
        Self.expectWithinTheLimits(hostile)

        for sample in [
            make(glucose: reading(), treatments: [carbs(35, minutesAgo: 6), bolus(3, minutesAgo: 8)]),
            make(glucose: reading(mgdl: 52), minPredBG: 30, displayUnits: "mmol/L", units: 0),
            make(glucose: reading(mgdl: 600, minutesAgo: 1440), displayUnits: "mmol/L"),
            make(loopMinutesAgo: 100_000, units: 0)
        ] {
            Self.expectWithinTheLimits(sample)
        }
    }

    @Test func theEncodedContextHasTheServicesKeysAndNoNulls() throws {
        let context = AIRequestContext(
            glucose: "142 mg/dL ↗",
            glucoseAgeMinutes: 3,
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8),
            noDoseReason: "glucose is low (52 mg/dL)"
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        #expect(Set(object.keys) == ["glucose", "glucoseAgeMinutes", "recentCarbs", "recentBolus", "noDoseReason"])
        let carbs = try #require(object["recentCarbs"] as? [String: Any])
        #expect(Set(carbs.keys) == ["amount", "minutesAgo"] && carbs["amount"] as? String == "20")
        // A fact Trio doesn't have is left out, not sent as null: the service refuses a null.
        let sparse = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AIRequestContext())) as? [String: Any])
        #expect(sparse.isEmpty)
        let partial = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AIRequestContext(glucose: "142 mg/dL"))) as? [String: Any]
        )
        #expect(Set(partial.keys) == ["glucose"])
    }

    @Test func minutesAreWholeNumbersFromZeroToADay() {
        let date = now
        #expect(AIRequestContext.minutes(from: date, to: now) == 0)
        #expect(AIRequestContext.minutes(from: date - 59, to: now) == 0)
        #expect(AIRequestContext.minutes(from: date - 60, to: now) == 1)
        #expect(AIRequestContext.minutes(from: date - 1440 * 60, to: now) == 1440)
        #expect(AIRequestContext.minutes(from: date - 1440 * 60 - 1, to: now) == nil)
        #expect(AIRequestContext.minutes(from: date + 1, to: now) == nil)
        #expect(AIRequestContext.minutes(from: .distantPast, to: now) == nil)
        #expect(AIRequestContext.minutes(from: .distantFuture, to: now) == nil)
    }

    @Test func textIsCutToFitAtAWholeCharacter() {
        #expect(AIRequestContext.fitted("abc", toUTF16Units: 5) == "abc")
        #expect(AIRequestContext.fitted("abcdef", toUTF16Units: 5) == "abcde")
        // 🍕 is two units: three of them don't fit in five, and the cut doesn't split the third.
        #expect(AIRequestContext.fitted("🍕🍕🍕", toUTF16Units: 5) == "🍕🍕")
        // A family emoji is one character of eight units.
        #expect(AIRequestContext.fitted("👨‍👩‍👧", toUTF16Units: 7) == nil)
        #expect(AIRequestContext.fitted("a👨‍👩‍👧", toUTF16Units: 9) == "a👨‍👩‍👧")
        #expect(AIRequestContext.fitted("a👨‍👩‍👧", toUTF16Units: 8) == "a")
        // Nothing left is nothing to send: the service refuses an empty string.
        #expect(AIRequestContext.fitted("", toUTF16Units: 5) == nil)
        #expect(AIRequestContext.fitted("abc", toUTF16Units: 0) == nil)
    }

    /// Every value, as trio-rc checks them: `glucose` 1–32, `amount` 1–16 and `noDoseReason` 1–120 UTF-16 units, and
    /// minutes from 0 to 1440.
    private static func expectWithinTheLimits(_ context: AIRequestContext, sourceLocation: SourceLocation = #_sourceLocation) {
        func check(_ text: String?, _ limit: Int, _ name: String) {
            guard let text else { return }
            #expect(!text.isEmpty && text.utf16.count <= limit, "\(name): \(text)", sourceLocation: sourceLocation)
        }
        func check(minutes: Int?, _ name: String) {
            guard let minutes else { return }
            #expect((0 ... 1440).contains(minutes), "\(name): \(minutes)", sourceLocation: sourceLocation)
        }
        check(context.glucose, 32, "glucose")
        check(minutes: context.glucoseAgeMinutes, "glucoseAgeMinutes")
        check(context.recentCarbs?.amount, 16, "recentCarbs.amount")
        check(minutes: context.recentCarbs?.minutesAgo, "recentCarbs.minutesAgo")
        check(context.recentBolus?.amount, 16, "recentBolus.amount")
        check(minutes: context.recentBolus?.minutesAgo, "recentBolus.minutesAgo")
        check(context.noDoseReason, 120, "noDoseReason")
    }
}
