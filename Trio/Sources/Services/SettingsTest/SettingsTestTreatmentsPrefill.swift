import Combine
import Foundation
import Observation
import SwiftUI

/// The carb ratio test's carbs, filled in on the Treatments sheet its Dose step opens (Open Treatments). It's Trio's own
/// sheet, and the user finishes it as one they opened themselves: its checks, warnings and Face ID all stay, and the
/// bolus isn't filled in. Only the carbs are, once the sheet's limits have loaded, and only on the sheet Open Treatments
/// opened: a sheet the user opens themselves, one an AI request fills in (`AIRequestTreatmentsSession`), and one that
/// already shows carbs are left alone.
///
/// A fill waits from `prepare(carbs:)` until the sheet appears, and is dropped once the router no longer shows the sheet:
/// when it closes (`sheetDisappeared`), or when the router leaves it before it appeared, so a later sheet the user opens
/// isn't filled in.
@MainActor final class SettingsTestTreatmentsPrefill {
    static let shared = SettingsTestTreatmentsPrefill()

    private let router: @MainActor() -> Router?
    /// Whether an AI request is filling the sheet in: its session has a request's sheet up.
    private let aiRequestFills: @MainActor() -> Bool
    /// Whether the carb ratio test's runner shows its tablets' carbs logged (`testCarbsLogged(in:)`): another fill
    /// would log them twice.
    private let testCarbsLogged: @MainActor() -> Bool

    /// The formatter of the sheet's carbs, fat and protein fields while the sheet Open Treatments sent is up: two
    /// decimals, as the AI request's (`AIRequestTreatmentsSession.makeGramFormatter`), so TruePlus tablets' 37.5 g stay
    /// 37.5 g instead of showing, and being written back, as 38. Set by `prepare` until that sheet closes, whether or
    /// not it was filled; `nil` otherwise, and the sheet keeps its own.
    private(set) var gramFormatter: NumberFormatter?

    /// The fill waiting for its sheet, from `prepare(carbs:)` until it is filled or the sheet closes.
    private var pending: Pending?
    /// Trio's router showed the sheet Open Treatments sent, so the router leaving it closes the sheet.
    private var sheetShown = false
    /// Follows the router from `prepare` until the sheet closes.
    private var routerSubscription: AnyCancellable?

    private struct Pending {
        let carbs: Decimal
        /// The sheet appeared, and was looked at for the fill.
        var appeared = false
        /// The sheet the fill is for, once it appeared, so a late callback from a closed sheet fills nothing.
        weak var sheet: Treatments.StateModel?
    }

    init(
        router: @escaping @MainActor() -> Router? = { TrioApp.resolver.resolve(Router.self) },
        aiRequestFills: @escaping @MainActor() -> Bool = { AIRequestTreatmentsSession.shared.requestID != nil },
        testCarbsLogged: @escaping @MainActor() -> Bool = {
            SettingsTestTreatmentsPrefill.testCarbsLogged(
                in: TrioApp.resolver.resolve(SettingsTestService.self)?.carbRatioRunner?.state.test
            )
        }
    ) {
        self.router = router
        self.aiRequestFills = aiRequestFills
        self.testCarbsLogged = testCarbsLogged
    }

    /// The gram fields' formatter for the Treatments sheet up now: an AI request's (`AIRequestTreatmentsSession`), else
    /// the carb ratio test's (`gramFormatter`), else nil, and the sheet keeps its own. What `TreatmentsRootView`'s one
    /// fork line reads, kept here so that line stays short.
    static var sheetGramFormatter: NumberFormatter? {
        AIRequestTreatmentsSession.shared.gramFormatter ?? shared.gramFormatter
    }

    /// Whether `test` has its tablets' carbs logged, before or after its bolus: a fill would log them twice.
    nonisolated static func testCarbsLogged(in test: CarbRatioTestState?) -> Bool {
        test?.carbsAt != nil
    }

    /// Whether a fill waits for its sheet. Internal, for tests.
    var isPending: Bool { pending != nil }

    /// Open Treatments is about to send the sheet: `carbs`, the tablets' grams, wait for it, and the sheet's gram fields
    /// keep their decimals until it closes. A fill already waiting is replaced. Refused while the carb ratio test shows
    /// its tablets' carbs logged (`testCarbsLogged`): filling them again would log them twice.
    func prepare(carbs: Decimal) {
        guard carbs > 0 else { return }
        guard !testCarbsLogged() else {
            debug(.settings, "SettingsTest: the carb ratio test's carbs are already logged, so none are filled in")
            return
        }
        pending = Pending(carbs: carbs)
        sheetShown = false
        gramFormatter = AIRequestTreatmentsSession.makeGramFormatter()
        routerSubscription = router()?.mainModalScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] screen in
                MainActor.assumeIsolated { self?.modalChanged(to: screen) }
            }
    }

    /// The Treatments sheet appeared. With a fill waiting, and no AI request filling the sheet, its carbs are filled in
    /// once its limits have loaded and only while it shows none, then `recalculate` works out the forecast and the
    /// recommendation for them. It's looked at once: a sheet that appears again isn't filled in again.
    func sheetAppeared(state: Treatments.StateModel, recalculate: @escaping () -> Void) {
        guard var pending, !pending.appeared else { return }
        guard !aiRequestFills() else {
            debug(.settings, "SettingsTest: an AI request fills the Treatments sheet, so the test's carbs aren't filled in")
            close()
            return
        }
        pending.appeared = true
        pending.sheet = state
        self.pending = pending
        fillWhenLimitsLoad(state, recalculate: recalculate)
    }

    /// The Treatments sheet disappeared. It's closed only if the router no longer shows it; otherwise it's still the open
    /// sheet.
    func sheetDisappeared() {
        guard pending != nil || gramFormatter != nil, router()?.mainModalScreen.value != .treatmentView else { return }
        close()
    }

    /// The sheet caps carbs at the user's Max Carbs, which is 0 until its settings have loaded, so the fill waits for it.
    /// Only for the sheet the fill is for: a callback from a sheet that closed since fills nothing.
    private func fillWhenLimitsLoad(_ state: Treatments.StateModel, recalculate: @escaping () -> Void) {
        guard let pending, pending.appeared, pending.sheet === state else { return }
        guard state.maxCarbs > 0 else {
            withObservationTracking {
                _ = state.maxCarbs
            } onChange: { [weak self, weak state] in
                // It's called as the value is about to change, so the value is read again once it has.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let state else { return }
                        self.fillWhenLimitsLoad(state, recalculate: recalculate)
                    }
                }
            }
            return
        }
        // Filled once, whatever came of it, so a sheet the user changed isn't filled in again. The formatter stays with
        // the sheet until it closes.
        self.pending = nil
        // Logged since `prepare`, by a sheet before this one: this one is for the bolus alone.
        guard !testCarbsLogged() else {
            debug(.settings, "SettingsTest: the carb ratio test's carbs were logged meanwhile, so none are filled in")
            return
        }
        guard state.carbs == 0 else {
            debug(.settings, "SettingsTest: the Treatments sheet already shows carbs, so the test's aren't filled in")
            return
        }
        state.carbs = pending.carbs
        debug(.settings, "SettingsTest: filled in the carb ratio test's carbs on the Treatments sheet")
        recalculate()
    }

    /// The router shows `screen`. Once it has shown the sheet, anything else means the sheet closed, or never appeared.
    private func modalChanged(to screen: Screen?) {
        if screen == .treatmentView {
            sheetShown = true
        } else if sheetShown {
            close()
        }
    }

    /// The sheet Open Treatments sent closed: no fill waits, and its gram fields go back to the sheet's own.
    private func close() {
        pending = nil
        gramFormatter = nil
        sheetShown = false
        routerSubscription = nil
    }
}

extension View {
    /// Lets the carb ratio test's Treatments sheet be filled in with its carbs when it appears, and heard when it
    /// disappears. A sheet the user opened themselves is left alone.
    func settingsTestTreatments(state: Treatments.StateModel, recalculate: @escaping () -> Void) -> some View {
        modifier(SettingsTestTreatmentsModifier(state: state, recalculate: recalculate))
    }
}

private struct SettingsTestTreatmentsModifier: ViewModifier {
    let state: Treatments.StateModel
    let recalculate: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                SettingsTestTreatmentsPrefill.shared.sheetAppeared(state: state, recalculate: recalculate)
            }
            .onDisappear {
                SettingsTestTreatmentsPrefill.shared.sheetDisappeared()
            }
    }
}
