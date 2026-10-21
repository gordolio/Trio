import SwiftUI

extension View {
    /// Opens an AI assistant's request on the watch's own carbs, bolus and Confirm screens, filled in with what the
    /// phone sent, and takes them down when the request's flow ends. Without a request, the screens are left alone.
    func aiRequestFlow(state: WatchState, navigationPath: Binding<NavigationPath>) -> some View {
        modifier(AIRequestFlowModifier(state: state, navigationPath: navigationPath))
    }
}

extension Text {
    /// The Confirm screen's carbs: the request's exact grams while a request is open with its carbs unchanged, and
    /// otherwise upstream's own localized text.
    init(aiRequestCarbs amount: Int) {
        if let text = AIRequestWatchFlowController.shared.carbsText(forAmount: amount) {
            self.init(verbatim: text)
        } else {
            self.init("\(amount) g")
        }
    }
}

/// Drives upstream's screens from `AIRequestWatchFlowController`: when a request opens, it fills in `WatchState` and
/// puts the Confirm screen on top, with the bolus and carbs screens behind it. It tells the controller when the wearer
/// leaves the screens, and when upstream zeroes their values. A flow that ends with a notice shows it in the watch's own
/// acknowledgement banner.
private struct AIRequestFlowModifier: ViewModifier {
    /// The controller's state the modifier follows, as one value, so a flow that ends with a notice is handled once.
    private struct Snapshot: Equatable {
        let phase: AIRequestWatchFlowController.Phase
        let notice: AIRequestWatchFlowController.Notice?
    }

    let state: WatchState
    @Binding var navigationPath: NavigationPath

    /// The request whose screens the modifier put up. Leaving them, or their values going to 0, counts only for it.
    @State private var shownID: String?

    private var controller: AIRequestWatchFlowController { .shared }

    func body(content: Content) -> some View {
        content
            .onChange(of: Snapshot(phase: controller.phase, notice: controller.notice), initial: true) { old, new in
                follow(from: old, to: new)
            }
            .onChange(of: navigationPath.count) { settle() }
            .onChange(of: state.carbsAmount) { settle() }
            .onChange(of: state.bolusAmount) { settle() }
    }

    private func follow(from old: Snapshot, to new: Snapshot) {
        if new.phase != old.phase {
            let phase = Self.describe(new.phase)
            Task { await WatchLogger.shared.log("AI requests: the watch flow is \(phase)") }
        }
        if let notice = new.notice, notice != old.notice {
            show(notice)
            return
        }
        switch new.phase {
        case let .active(details):
            if new.phase != old.phase || shownID != details.id {
                open(details)
            }
        case .confirmed:
            shownID = nil
        case .idle,
             .loading,
             .unreachable:
            // The flow ended, or another request is opening: its screens go, so nothing on them reaches upstream's sends.
            if shownID != nil {
                shownID = nil
                navigationPath = NavigationPath()
            }
        }
    }

    /// Fills in the screens with the request, and opens the Confirm screen with the bolus screen behind it, and the
    /// carbs screen behind that when there are carbs.
    private func open(_ details: AIRequestWatchDetails) {
        let carbs = controller.requestedCarbs
        // Upstream's own sends show "Processing…" on the acknowledgement screen that follows; a caught send does too.
        controller.onIntercepted = { [state] in
            state.showCommsAnimation = true
        }
        state.carbsAmount = carbs
        state.recommendedBolus = details.units
        state.bolusAmount = Double(truncating: details.units as NSNumber)
        state.confirmationProgress = 0

        var path = NavigationPath()
        if carbs > 0 {
            path.append(NavigationDestinations.carbsInput)
        }
        path.append(NavigationDestinations.bolusInput)
        path.append(NavigationDestinations.bolusConfirm)
        navigationPath = path
        shownID = details.id
    }

    /// Shows the notice on the acknowledgement screen, with upstream's own banner, which goes back to the main screen
    /// when it hides.
    private func show(_ notice: AIRequestWatchFlowController.Notice) {
        shownID = nil
        var path = NavigationPath()
        path.append(NavigationDestinations.acknowledgmentPending)
        navigationPath = path
        state.isMealBolusCombo = false
        state.handleAcknowledgment(success: notice.isSuccess, message: notice.message)
    }

    /// Leaving the screens declines the request. Upstream zeroing their values under them (when the phone becomes
    /// reachable again) ends the flow without an answer.
    private func settle() {
        guard case let .active(details) = controller.phase, shownID == details.id else { return }
        if navigationPath.isEmpty {
            controller.pathEmptied()
        } else if state.carbsAmount == 0, state.bolusAmount == 0 {
            controller.valuesZeroed()
        }
    }

    private static func describe(_ phase: AIRequestWatchFlowController.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case let .loading(id): return "waiting for \(id)'s details"
        case let .unreachable(id): return "unable to reach the phone for \(id)"
        case let .active(details): return "showing \(details.id)"
        case let .confirmed(id): return "confirmed \(id)"
        }
    }
}
