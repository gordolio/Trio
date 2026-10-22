import SwiftUI

extension View {
    /// Opens an AI assistant's request on the watch's own carbs, bolus and Confirm screens, filled in with what the
    /// phone sent, and takes them down when the request's flow ends. Without a request, the screens are left alone.
    func aiRequestFlow(
        state: WatchState,
        navigationPath: Binding<NavigationPath>,
        continueToBolus: Binding<Bool>
    ) -> some View {
        modifier(AIRequestFlowModifier(state: state, navigationPath: navigationPath, continueToBolus: continueToBolus))
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
/// puts the Confirm screen on top, with the bolus and carbs screens behind it. It reports the screens back to the
/// controller after each change, which decides what leaving them, another flow on top of them, or their values going
/// to 0 means. A flow that ends with a notice shows it in the watch's own acknowledgement banner.
private struct AIRequestFlowModifier: ViewModifier {
    /// The controller's state the modifier follows, as one value, so a flow that ends with a notice is handled once.
    private struct Snapshot: Equatable {
        let phase: AIRequestWatchFlowController.Phase
        let notice: AIRequestWatchFlowController.Notice?
    }

    let state: WatchState
    @Binding var navigationPath: NavigationPath
    /// Upstream's flag that makes the carbs screen lead on to the bolus screen ("Proceed") rather than log carbs alone.
    @Binding var continueToBolus: Bool

    private var controller: AIRequestWatchFlowController { .shared }

    func body(content: Content) -> some View {
        content
            .onChange(of: Snapshot(phase: controller.phase, notice: controller.notice), initial: true) { old, new in
                follow(from: old, to: new)
            }
            .onChange(of: navigationPath.count, initial: true) { report() }
            .onChange(of: state.carbsAmount) { report() }
            .onChange(of: state.bolusAmount) { report() }
            .onChange(of: state.bolusIncrement, initial: true) {
                controller.bolusIncrement = state.bolusIncrement
            }
    }

    private func follow(from old: Snapshot, to new: Snapshot) {
        // `onChange` only calls with equal values the first time, when the modifier appears.
        let isFirst = old == new
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
            if isFirst || new.phase != old.phase {
                open(details)
            }
        case .idle:
            // The wearer left the request's screens, and their values go. If the wearer started another flow on top of
            // them instead, the values went as it started (`onAnotherFlowStarted`), and that flow's screens stay.
            if case .active = old.phase, navigationPath.isEmpty {
                clearScreens()
            }
        case .loading,
             .unreachable:
            // Another request is opening: the earlier screens and their values go.
            if case .active = old.phase {
                clearScreens()
                navigationPath = NavigationPath()
            }
        case .closing,
             .confirmed:
            break
        }
    }

    /// Fills in the screens with the request, and opens the Confirm screen with the bolus screen behind it, and the
    /// carbs screen behind that when there are carbs. Back on the carbs screen, "Proceed" leads on to the bolus screen.
    private func open(_ details: AIRequestWatchDetails) {
        let carbs = controller.requestedCarbs
        let bolus = controller.loadedBolus(for: details.units)
        // Upstream's own sends show "Processing…" on the acknowledgement screen that follows; a caught send does too.
        controller.onIntercepted = { [state] in
            state.showCommsAnimation = true
        }
        // The confirm sends the dose Confirm shows, from the Double it floors.
        controller.screenBolus = { [state] in
            state.bolusAmount
        }
        // A flow the wearer starts on top of the request's screens starts as upstream's own do, not from the request's
        // carbs and dose: the bolus screen otherwise shows the request's dose until the phone's recommendation comes.
        controller.onAnotherFlowStarted = { [state] in
            state.carbsAmount = 0
            state.bolusAmount = 0
            state.recommendedBolus = 0
            state.confirmationProgress = 0
        }
        state.carbsAmount = carbs
        state.recommendedBolus = details.units
        state.bolusAmount = bolus
        state.confirmationProgress = 0
        continueToBolus = true

        var path = NavigationPath()
        if carbs > 0 {
            path.append(NavigationDestinations.carbsInput)
        }
        path.append(NavigationDestinations.bolusInput)
        path.append(NavigationDestinations.bolusConfirm)
        navigationPath = path
        controller.screensChanged(pathCount: path.count, carbs: carbs, bolus: bolus)
    }

    /// Shows the notice on the acknowledgement screen, with upstream's own banner, which goes back to the main screen
    /// when it hides. The flow ended without the watch's confirm, so the screens' values go, and nothing on them can be
    /// sent.
    private func show(_ notice: AIRequestWatchFlowController.Notice) {
        clearScreens()
        var path = NavigationPath()
        path.append(NavigationDestinations.acknowledgmentPending)
        navigationPath = path
        state.isMealBolusCombo = false
        state.handleAcknowledgment(success: notice.isSuccess, message: notice.message)
    }

    /// Zeroes the screens' carbs, bolus and crown progress, so a send still to come from them carries nothing.
    private func clearScreens() {
        state.carbsAmount = 0
        state.bolusAmount = 0
        state.confirmationProgress = 0
    }

    private func report() {
        controller.screensChanged(
            pathCount: navigationPath.count,
            carbs: state.carbsAmount,
            bolus: state.bolusAmount
        )
    }

    private static func describe(_ phase: AIRequestWatchFlowController.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case let .loading(id): return "waiting for \(id)'s details"
        case let .unreachable(id): return "unable to reach the phone for \(id)"
        case let .active(details): return "showing \(details.id)"
        case let .confirmed(id): return "confirmed \(id)"
        case let .closing(id): return "closing \(id)"
        }
    }
}
