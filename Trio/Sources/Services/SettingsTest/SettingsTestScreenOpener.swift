import Combine
import Foundation
import SwiftUI
import UserNotifications

/// The one-line hook the notifications manager calls. A notification that isn't a settings test's is left to the
/// file it's called from, which carries on as before.
enum SettingsTestHooks {
    /// Opens the test's screen when the wearer taps one of its notifications. Returns `true` if it was one, so the
    /// notifications manager must not handle it; the completion handler is then called once.
    static func didReceive(_ response: UNNotificationResponse, _ completion: @escaping () -> Void) -> Bool {
        let content = response.notification.request.content
        return didReceive(
            category: content.categoryIdentifier,
            userInfo: content.userInfo,
            completion,
            open: { kind in _ = SettingsTestScreenOpener.shared.open(kind) }
        )
    }

    /// The same for a notification's category and user info, with what opens the screen passed in: the completion handler is
    /// called once, and only for a settings test's notice.
    static func didReceive(
        category: String,
        userInfo: [AnyHashable: Any],
        _ completion: @escaping () -> Void,
        open: @escaping @MainActor(SettingsTestKind) -> Void
    ) -> Bool {
        guard let kind = kind(category: category, userInfo: userInfo) else { return false }
        Task { @MainActor in open(kind) }
        completion()
        return true
    }

    /// The kind a tapped notification names, or nil when it isn't a settings test's.
    static func kind(category: String, userInfo: [AnyHashable: Any]) -> SettingsTestKind? {
        guard category == SettingsTestNotice.category,
              let raw = userInfo[SettingsTestNotice.kindKey] as? String
        else { return nil }
        return SettingsTestKind(rawValue: raw)
    }
}

extension SettingsTestKind {
    /// The screen a tap on the kind's notification opens, or nil while it has none.
    var testScreen: Screen? {
        switch self {
        case .basal: return .basalTest
        case .isf: return .isfTest
        case .carbRatio: return .carbRatioTest
        }
    }
}

/// Opens a settings test's screen for a tap on its notification. The screen never covers or dismisses another sheet:
/// the kind waits as `pending` and opens as soon as the other sheet has closed.
///
/// A kind stays pending until its screen has appeared, not until it was sent to the router. Sent at launch, before
/// `Main.StateModel` subscribes to the router, it is wiped again as Main appears (Main's `$modal` sends `nil` to the
/// router for its first value), so the opener sends it again whenever the router is free and the screen isn't showing.
/// A kind that waits for another sheet is sent as soon as the router changes and is free; one that was sent and didn't
/// appear is sent again on the 1 s timer only. Main's pipelines echo a `nil` they were sent back to the router once more,
/// a turn or two later, and a screen sent again in between is wiped by that echo, again and again, until the opener
/// gives up. A second later they have settled.
///
/// A tap still pending when Trio goes to the background is dropped, so a sheet that closes much later doesn't bring a
/// screen up uninvited, and the 1 s re-check doesn't run in the background.
@MainActor final class SettingsTestScreenOpener {
    static let shared = SettingsTestScreenOpener()

    /// The most times a screen is sent again after it didn't appear, before the opener gives up on a tap, so a screen
    /// that can't show doesn't loop. An app limit.
    static let maxRepresents = 5
    /// What `screenAppeared` and `screenDisappeared` use for a screen when the caller gives no view of its own.
    nonisolated static let anonymousView = UUID()

    private let router: @MainActor() -> Router?
    /// Whether the app's key window shows anything over the app: a sheet, a cover or an alert, Trio's router's or not.
    private let keyWindowPresents: @MainActor() -> Bool
    /// What drives the re-check while a kind is pending, for a sheet that is still animating out when the router says it
    /// is gone. A fresh publisher each time, subscribed only while a kind is pending.
    private let recheckTicks: () -> AnyPublisher<Void, Never>

    /// The kind waiting to be shown, if any: for another sheet to close, or for its screen to appear once sent (the
    /// latest tap wins).
    private(set) var pending: SettingsTestKind?
    /// How many times the pending kind's screen was sent to the router without appearing.
    private var presents = 0
    private var recheck: AnyCancellable?
    /// Whether the re-check also watches the router's changes: not when it began before there was a router.
    private var recheckWatchesRouter = false
    /// The views showing each kind's screen, by identity: a view that appears twice without disappearing is still one
    /// view, so a duplicate `onAppear` can't leave a screen counted as showing after it has gone.
    private var showing: [SettingsTestKind: Set<UUID>] = [:]
    /// The kinds whose screen showing now is one this opener presented.
    private var openedFromNotice: Set<SettingsTestKind> = []
    /// The pending kind, when `treatmentsOpened` made it pending: it waits for Treatments to take its screen's place.
    private var awaitsTreatments: SettingsTestKind?
    /// Drops a pending tap when Trio goes to the background.
    private var backgroundSubscription: AnyCancellable?

    /// `backgrounded` emits each time Trio goes to the background, on the main thread.
    init(
        router: @escaping @MainActor() -> Router? = { TrioApp.resolver.resolve(Router.self) },
        keyWindowPresents: @escaping @MainActor() -> Bool = { AIRequestTreatmentsOpener.keyWindowPresentsAnything() },
        recheckTicks: @escaping () -> AnyPublisher<Void, Never> = {
            Timer.publish(every: 1, on: .main, in: .common).autoconnect().map { _ in () }.eraseToAnyPublisher()
        },
        backgrounded: AnyPublisher<Void, Never> = Foundation.NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .map { _ in () }
            .eraseToAnyPublisher()
    ) {
        self.router = router
        self.keyWindowPresents = keyWindowPresents
        self.recheckTicks = recheckTicks
        backgroundSubscription = backgrounded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dropPending() }
    }

    /// Drops the tap waiting to be shown, if any, as Trio goes to the background.
    private func dropPending() {
        guard pending != nil else { return }
        debug(.settings, "SettingsTest: Trio went to the background, so the tap waiting to open its screen is dropped")
        stopWaiting()
    }

    /// Whether the 1 s re-check runs: only while a kind is pending.
    var isRechecking: Bool { recheck != nil }

    /// Opens the kind's screen if nothing else is shown, and returns whether it sent it. Another sheet being open, or
    /// still closing, keeps the kind pending instead. Either way the kind stays pending until its screen appears. No
    /// second copy of a screen that is showing is opened, and a kind with no screen opens nothing. A tap whose screen is
    /// showing is still the latest tap: an older one waiting for another kind is dropped, so closing this screen doesn't
    /// bring that one up.
    @discardableResult func open(_ kind: SettingsTestKind) -> Bool {
        guard kind.testScreen != nil else { return false }
        guard !isShowing(kind) else {
            if let waiting = pending, waiting != kind {
                debug(.settings, "SettingsTest: a newer tap's screen is showing, so the \(waiting.rawValue) tap no longer waits")
                stopWaiting()
            }
            return false
        }
        // At a launch from closed the router may not be there yet: the kind waits for it, on the 1 s timer.
        guard let router = router() else {
            keepPending(kind, router: nil)
            return false
        }
        guard isFree(router) else {
            keepPending(kind, router: router)
            return false
        }
        present(kind, on: router)
        return true
    }

    /// Whether the kind's screen showing now is one this opener presented (from a notice). Cleared when it disappears.
    func wasOpenedFromNotice(_ kind: SettingsTestKind) -> Bool {
        isShowing(kind) && openedFromNotice.contains(kind)
    }

    /// Called by a notice-opened test screen's Open Treatments, before it sends Treatments: keeps the kind pending, so the
    /// test comes back when Treatments closes. If the test screen goes while the router isn't showing Treatments, the
    /// sheet was closed and Treatments never opened, so the kind is dropped (`screenDisappeared`): a screen the user
    /// closed doesn't come back.
    func treatmentsOpened(from kind: SettingsTestKind) {
        guard kind.testScreen != nil, let router = router() else { return }
        keepPending(kind, router: router)
        awaitsTreatments = kind
    }

    /// `viewID` names the view, so the same view appearing again is no second copy.
    func screenAppeared(_ kind: SettingsTestKind, viewID: UUID = anonymousView) {
        showing[kind, default: []].insert(viewID)
        // The screen this opener sent has arrived. One that came from Settings while the kind waited isn't from a
        // notice, and has nothing left to wait for.
        guard pending == kind else { return }
        if presents > 0 {
            openedFromNotice.insert(kind)
        }
        stopWaiting()
    }

    func screenDisappeared(_ kind: SettingsTestKind, viewID: UUID = anonymousView) {
        showing[kind]?.remove(viewID)
        guard showing[kind]?.isEmpty ?? true else { return }
        showing[kind] = nil
        openedFromNotice.remove(kind)
        // Waiting for Treatments, and gone without Treatments in its place (`treatmentsOpened`).
        if awaitsTreatments == kind, pending == kind, router()?.mainModalScreen.value != .treatmentView {
            stopWaiting()
        }
    }

    func isShowing(_ kind: SettingsTestKind) -> Bool {
        !(showing[kind]?.isEmpty ?? true)
    }

    // MARK: - Waiting

    /// Sheets and covers shown outside the router count too, such as Home's own.
    private func isFree(_ router: Router) -> Bool {
        router.mainModalScreen.value == nil && router.mainSecondaryModalView.value == nil && !keyWindowPresents()
    }

    private func present(_ kind: SettingsTestKind, on router: Router) {
        guard let screen = kind.testScreen else { return }
        keepPending(kind, router: router)
        presents += 1
        router.mainModalScreen.send(screen)
    }

    /// Keeps `kind` pending, in place of any other, and looks again whenever a sheet opens or closes and every second.
    /// Without a router (`nil`, a launch before the app's services exist) it looks on the timer only, and watches the
    /// router's changes too from the first look that finds one.
    private func keepPending(_ kind: SettingsTestKind, router: Router?) {
        if pending != kind {
            pending = kind
            presents = 0
            awaitsTreatments = nil
        }
        guard recheck == nil || (router != nil && !recheckWatchesRouter) else { return }
        recheckWatchesRouter = router != nil
        var sources = [recheckTicks().map { true }.eraseToAnyPublisher()]
        if let router {
            // The current values are skipped: nothing has changed since the caller looked. A change of the router is
            // looked at on the next turn of the main queue, never inside the router's own delivery: sending the screen
            // from there would reach a subscriber that comes after this one as the screen and then the `nil` it was sent
            // in answer to, and leave it with the `nil`.
            sources.append(
                Publishers.Merge(
                    router.mainModalScreen.dropFirst().map { _ in () },
                    router.mainSecondaryModalView.dropFirst().map { _ in () }
                )
                .receive(on: DispatchQueue.main)
                .map { false }
                .eraseToAnyPublisher()
            )
        }
        recheck = Publishers.MergeMany(sources)
            .sink { [weak self] isTick in self?.openPending(onTick: isTick) }
    }

    private func stopWaiting() {
        pending = nil
        presents = 0
        recheck = nil
        recheckWatchesRouter = false
        awaitsTreatments = nil
    }

    private func openPending(onTick: Bool) {
        // A screen that was sent and didn't appear is sent again on the timer only (see the type's comment).
        guard let kind = pending, onTick || presents == 0, let router = router() else { return }
        // A look that began before there was a router watches its changes from the first look that finds one.
        if !recheckWatchesRouter {
            keepPending(kind, router: router)
        }
        guard isFree(router) else { return }
        // Opened by the user meanwhile, from Settings: nothing to add.
        guard !isShowing(kind) else {
            stopWaiting()
            return
        }
        guard presents <= Self.maxRepresents else {
            warning(
                .settings,
                "SettingsTest: the \(kind.rawValue) test's screen didn't appear after \(presents) tries, so it isn't opened again"
            )
            stopWaiting()
            return
        }
        present(kind, on: router)
    }
}

extension View {
    /// Tells the opener this test's screen is on screen, so a tap on its notification opens no second copy.
    func settingsTestScreen(_ kind: SettingsTestKind) -> some View {
        modifier(SettingsTestScreenModifier(kind: kind))
    }
}

private struct SettingsTestScreenModifier: ViewModifier {
    let kind: SettingsTestKind
    /// This view's own identity, so a duplicate `onAppear` is no second copy.
    @State private var viewID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { SettingsTestScreenOpener.shared.screenAppeared(kind, viewID: viewID) }
            .onDisappear { SettingsTestScreenOpener.shared.screenDisappeared(kind, viewID: viewID) }
    }
}
