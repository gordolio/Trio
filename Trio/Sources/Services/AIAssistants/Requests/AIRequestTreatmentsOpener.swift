import Foundation
import SwiftUI
import UIKit

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
    /// Whether the app's key window shows anything over the app: a sheet, a cover or an alert, Trio's router's or not.
    private let keyWindowPresents: @MainActor() -> Bool

    init(
        router: @escaping @MainActor() -> Router? = { TrioApp.resolver.resolve(Router.self) },
        coordinator: @escaping () -> AIRequestCoordinator? = { AIRequestsRuntime.shared?.coordinator },
        session: AIRequestTreatmentsSession? = nil,
        now: @escaping () -> Date = Date.init,
        isDue: @escaping (PendingAIRequest, Date) async -> Bool = { await AIRequestPhoneBackup().isDue($0, now: $1) },
        keyWindowPresents: @escaping @MainActor() -> Bool = { AIRequestTreatmentsOpener.keyWindowPresentsAnything() }
    ) {
        self.router = router
        self.coordinator = coordinator
        self.session = session ?? .shared
        self.now = now
        self.isDue = isDue
        self.keyWindowPresents = keyWindowPresents
    }

    /// Whether the key window's root view controller presents a view controller.
    static func keyWindowPresentsAnything() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .presentedViewController != nil
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

    /// Opens the sheet for the pending request if it's `wanted`, its time isn't up, and no other sheet is open.
    private func openPending(if wanted: (PendingAIRequest) async -> Bool) async {
        guard let coordinator = coordinator(), let router = router() else { return }
        // Before the pending request is read, so the sheet hears it leave from here on.
        session.follow()
        // Reads the pending request from disk on a cold launch, and drops it if its time is up.
        await coordinator.expireIfDue()
        guard let candidate = coordinator.current.value, await wanted(candidate) else { return }
        // Read again after the waits.
        guard let pending = coordinator.current.value, pending.request.id == candidate.request.id else { return }
        let id = pending.request.id
        // Sheets and covers shown outside the router count too, such as Home's own. The request's own sheet counts as
        // well: it keeps holding the request.
        guard router.mainModalScreen.value == nil, router.mainSecondaryModalView.value == nil, !keyWindowPresents() else {
            debug(.service, "AI requests: another sheet is open, so \(id) isn't opened")
            return
        }
        // A request whose time is up is still pending only while a screen holds it. It isn't opened fresh: opening it
        // lets go of a hold the iPhone kept, and the coordinator expires it unless the watch holds it.
        guard now() < pending.request.expiresAt else {
            _ = await coordinator.open(id: id, on: .phone)
            debug(.service, "AI requests: \(id)'s time is up, so it isn't opened")
            return
        }
        // Nothing waits from here until the sheet is asked for.
        session.begin(pending)
        router.mainModalScreen.send(.treatmentView)
        // Holds the request's expiry while the sheet is up. Without the hold, the request isn't opened: its time ran out
        // as the sheet opened. A request that left pending meanwhile closes the sheet itself, with its notice.
        if await coordinator.open(id: id, on: .phone) == nil, coordinator.current.value?.request.id == id {
            session.notOpened(id)
        }
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
