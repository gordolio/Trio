import XCTest

/// UI regression scaffold for the July 29, 2026 auto-applied bolus bug.
///
/// Before running, configure the simulator with fresh loop data that reproduces the reported case:
/// current glucose around 71 mg/dL, 15 g newly entered carbs, approximately 1.19 U IOB, and a
/// recommendation around 1.4 U whose applied forecast falls below 54 mg/dL.
final class AutoAppliedBolusRegressionUITests: XCTestCase {
    func testVeryLowForecastDoesNotAutoApplyRecommendation() {
        let app = XCUIApplication()
        app.launch()

        openTreatments(in: app)
        enterCarbs(15, in: app)

        let warning = app.staticTexts["Glucose forecast is very low."]
        XCTAssertTrue(
            warning.waitForExistence(timeout: 30),
            "The simulator data did not reproduce the very-low post-bolus forecast. See README.md."
        )

        let bolusField = app.textFields.allElementsBoundByIndex.last
        XCTAssertNotNil(bolusField, "Could not locate the Bolus field on Treatments.")

        let bolusValue = bolusField?.value as? String
        XCTAssertTrue(
            bolusValue == nil || bolusValue == "" || bolusValue == "0",
            "The recommendation was automatically copied into Bolus (value: \(bolusValue ?? "nil"))."
        )
    }

    private func openTreatments(in app: XCUIApplication) {
        if app.navigationBars["Treatments"].exists {
            return
        }

        let addButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'add' OR label == 'plus'")
        ).firstMatch
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 15),
            "Could not find the Home add-treatment button. Complete onboarding before running this test."
        )
        addButton.tap()

        XCTAssertTrue(app.navigationBars["Treatments"].waitForExistence(timeout: 10))
    }

    private func enterCarbs(_ grams: Int, in app: XCUIApplication) {
        let numericFields = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0'")
        )
        let carbsField = numericFields.firstMatch
        XCTAssertTrue(carbsField.waitForExistence(timeout: 10), "Could not locate the Carbs field.")

        carbsField.tap()
        carbsField.typeText(String(grams))
    }
}
