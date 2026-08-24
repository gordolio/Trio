# Auto-Applied Bolus UI Regression

This scaffold targets the broken July 29, 2026 revision (`c69ec1ef6`). It intentionally lives outside the upstream Xcode project so the branch does not modify upstream-owned files.

## Xcode Setup

1. Open `Trio.xcodeproj` on a Mac.
2. Add an iOS UI Testing Bundle named `TrioUITests` targeting `Trio`.
3. Add `AutoAppliedBolusRegressionUITests.swift` to that target without copying it.
4. Use a simulator that has completed onboarding and has a configured pump/profile.

## Reproduction Data

The original report showed approximately:

- Current glucose: 71 mg/dL
- New carbs: 15 g
- IOB: 1.19 U
- COB: 69 g
- Target: 117 mg/dL
- ISF: 88 mg/dL/U
- Fifteen-minute delta: -23 mg/dL
- Recommendation: 1.4 U
- Forecast after applying 1.4 U: below 54 mg/dL

Seed or replay comparable recent glucose, determination, IOB, and COB data before running the test. The test enters the additional 15 g itself.

## Expected Result

On `c69ec1ef6`, the test should reach the low-forecast warning and fail because the Bolus field contains the automatically applied recommendation.

After removing auto-apply, the recommendation may still be displayed, but the Bolus field should remain empty or zero until the user explicitly accepts it.

The field lookup currently uses the first zero-placeholder text field for Carbs and the final text field for Bolus. Replace those selectors with accessibility identifiers if upstream adds stable identifiers later.
