import Foundation
import SwiftUI

/// Opens Trio's Treatments sheet for the pending request: when the wearer taps its iPhone notification, or brings Trio to
/// the front while the iPhone is asking for it. The sheet opens only when no other sheet is open. Otherwise nothing
/// opens, then or later on its own: the request keeps waiting until the wearer opens it again, or it expires.
@MainActor final class AIRequestTreatmentsOpener {
    static let shared = AIRequestTreatmentsOpener()

    private let router: @MainActor() -> Router?
    private let coordinator: () -> AIRequestCoordinator?
    private let session: AIRequestTreatmentsSession
    private let now: () -> Date
    /// Whether the iPhone is asking for the request at the date, rather than the watch alone.
    private let isDue: (PendingAIRequest, Date) async -> Bool

    init(
        router: @escaping @MainActor() -> Router? = { TrioApp.resolver.resolve(Router.self) },
        coordinator: @escaping () -> AIRequestCoordinator? = { AIRequestsRuntime.shared?.coordinator },
        session: AIRequestTreatmentsSession? = nil,
        now: @escaping () -> Date = Date.init,
        isDue: @escaping (PendingAIRequest, Date) async -> Bool = { await AIRequestPhoneBackup().isDue($0, now: $1) }
    ) {
        self.router = router
        self.coordinator = coordinator
        self.session = session ?? .shared
        self.now = now
        self.isDue = isDue
    }

    /// Opens the sheet for the request whose notification the wearer tapped, if it's the pending one. The task is the
    /// opening, which the caller needn't wait for.
    @discardableResult func open(requestID: String) -> Task<Void, Never> {
        Task { await openPending { $0.request.id == requestID } }
    }

    /// Opens the sheet for the pending request when Trio comes to the front, if the iPhone is asking for it, so it
    /// doesn't take a tap on a notification that was cleared, grouped or lost on a cold launch.
    func openDueRequest() async {
        let now = now
        let isDue = isDue
        await openPending { await isDue($0, now()) }
    }

    /// Opens the sheet for the pending request if it's `wanted` and no other sheet is open.
    private func openPending(if wanted: (PendingAIRequest) async -> Bool) async {
        guard let coordinator = coordinator(), let router = router() else { return }
        // Before the pending request is read, so the sheet hears it leave from here on.
        session.follow()
        // Reads the pending request from disk on a cold launch, and drops it if its time is up.
        await coordinator.expireIfDue()
        guard let candidate = coordinator.current.value, await wanted(candidate) else { return }
        // Read again after the waits. Nothing waits from here until the sheet is asked for.
        guard let pending = coordinator.current.value, pending.request.id == candidate.request.id else { return }
        guard router.mainModalScreen.value == nil, router.mainSecondaryModalView.value == nil else {
            debug(.service, "AI requests: another sheet is open, so \(pending.request.id) isn't opened")
            return
        }
        session.begin(pending)
        router.mainModalScreen.send(.treatmentView)
        // Holds the request's expiry while the sheet is up.
        _ = await coordinator.open(id: pending.request.id, on: .phone)
    }
}

extension View {
    /// Opens the Treatments sheet for the pending request when Trio comes to the front while the iPhone is asking for
    /// it. A tap on the request's notification opens it through `AIRequestHooks`.
    func aiRequestTreatmentsOpener() -> some View {
        modifier(AIRequestTreatmentsOpenerModifier())
    }
}

private struct AIRequestTreatmentsOpenerModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // On a cold launch the scene is already active when the app shows, so its phase doesn't change.
            .onAppear {
                if scenePhase == .active {
                    Task { await AIRequestTreatmentsOpener.shared.openDueRequest() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await AIRequestTreatmentsOpener.shared.openDueRequest() }
                }
            }
    }
}
