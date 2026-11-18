import SwiftUI

extension CarbRatioTest.CheckView {
    /// Every step, as each one's screen and the runner run it, for the steps sheet.
    static func steps() -> [SettingsTestStepItem<CarbRatioTest.Step>] {
        let readings = CarbRatioTest.Config.settleReadings
        let doseMinutes = Int(CarbRatioTest.Config.doseAllowance / 60)
        let carbsMinutes = Int(CarbRatioTest.Config.mealPairing / 60)
        return [
            .init(
                step: .check,
                detail: Text(
                    "The checks, then a page each for your tablets, how long to watch and, when it's over the test's line, insulin on board. Begin turns on once each check passes."
                )
            ),
            .init(
                step: .settle,
                detail: Text(
                    "Trio switches to Basal Testing, so SMBs stop. The test waits for Trio's first loop in it and \(readings) CGM readings after that. If you chose Wait for It, it also waits, up to an hour, for insulin on board to come within the line of zero."
                )
            ),
            .init(
                step: .dose,
                detail: Text(
                    "The step works out the bolus for the tablets from your carb ratio and waits for a flat CGM arrow, or a recent reading with none. You open Treatments, check the carbs and give the bolus with them within \(doseMinutes) minutes, then take the tablets. The carbs and the bolus must come within \(carbsMinutes) minutes of each other."
                )
            ),
            .init(
                step: .wait,
                detail: Text(
                    "3 or 4 hours, as you chose, without eating or exercising. Other carbs or another bolus end the test."
                )
            ),
            .init(
                step: .result,
                detail: Text(
                    "Where glucose ended against where it started, the carb ratio that shows, and which way yours leans."
                )
            )
        ]
    }
}
