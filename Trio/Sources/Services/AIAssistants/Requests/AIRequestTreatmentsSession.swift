import Combine
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// The Treatments sheet that a request opened. It's Trio's own sheet, filled in with the request, and the wearer
/// finishes it like a meal they typed themselves: the sheet's own checks, warnings and Face ID all stay. The session
/// fills the sheet in once the wearer's limits have loaded, keeps the request's decimals in its gram fields, and reports
/// what the sheet did: what was logged and given if the wearer submitted it, or a decline if they closed it. If the
/// request leaves pending while the sheet is open, as when it was logged on the watch, the session closes the sheet and
/// says why in a notice.
///
/// The sheet is closed when Trio's router no longer shows it. It can disappear while it's still shown, under a cover
/// such as the AI food chat, and then it comes back.
///
/// What a submit did is read from the sheet's own state, not from the sheet closing: upstream can close the sheet on any
/// loop run while Face ID is up, and give the bolus after. So a submit is watched until its outcome is known, after the
/// sheet has closed if need be, for at most `outcomeWait`. An outcome still unknown then isn't reported at all.
///
/// A Treatments sheet the wearer opens themselves isn't a request's, and the session leaves it alone.
@MainActor final class AIRequestTreatmentsSession {
    static let shared = AIRequestTreatmentsSession()

    /// The formatter of the sheet's carbs, fat and protein fields while a request's sheet is up: up to three whole digits
    /// and two decimals, so the request's 82.5 g stays 82.5 g. It's `nil` otherwise, and the sheet keeps its own.
    private(set) var gramFormatter: NumberFormatter?

    /// The request whose sheet is up, from `begin(_:)` until the sheet closes.
    var requestID: String? { active?.pending.request.id }

    /// How long after Log a submit's outcome is waited for.
    static let outcomeWait: TimeInterval = 120

    private let coordinator: () -> AIRequestCoordinator?
    private let router: @MainActor() -> Router?
    private let notifications: () -> AIRequestNotificationScheduling
    private let bolusSignals: @MainActor() -> AIRequestBolusSignals?
    /// Sends once the seconds have passed.
    private let deadline: (TimeInterval) -> AnyPublisher<Void, Never>

    private var active: Active?
    /// The coordinator whose `left` the session follows.
    private var followedID: ObjectIdentifier?
    private var leftSubscription: AnyCancellable?
    /// Follows the router while a request's sheet is up.
    private var routerSubscription: AnyCancellable?
    /// The submits whose outcome is still watched, which can be after their sheet closed.
    private var watched: [ObjectIdentifier: Submission] = [:]

    /// Sent when a bolus asked for on the sheet failed, and Trio has no error saying why.
    fileprivate static let bolusFailedReason = String(
        localized: "Bolus failed",
        comment: "Report reason: the bolus the wearer asked for on the Treatments sheet failed"
    )

    /// A request's sheet, from `begin(_:)` until it closes.
    private struct Active {
        let pending: PendingAIRequest
        /// The sheet appeared.
        var appeared = false
        /// Trio's router showed the sheet, so the router leaving it closes the sheet.
        var shown = false
        /// Its fields hold the request.
        var filled = false
        /// The request left pending some other way, so the sheet reports nothing.
        var leftElsewhere = false
        var submission: Submission?
    }

    init(
        coordinator: @escaping () -> AIRequestCoordinator? = { AIRequestsRuntime.shared?.coordinator },
        router: @escaping @MainActor() -> Router? = { TrioApp.resolver.resolve(Router.self) },
        notifications: @escaping () -> AIRequestNotificationScheduling = { UNUserNotificationCenter.current() },
        bolusSignals: @escaping @MainActor() -> AIRequestBolusSignals? = { AIRequestBolusSignals.live() },
        deadline: @escaping (TimeInterval) -> AnyPublisher<Void, Never> = { seconds in
            Just(()).delay(for: .seconds(seconds), scheduler: DispatchQueue.main).eraseToAnyPublisher()
        }
    ) {
        self.coordinator = coordinator
        self.router = router
        self.notifications = notifications
        self.bolusSignals = bolusSignals
        self.deadline = deadline
    }

    // MARK: Opening

    /// Follows the coordinator's `left`, once, so the sheet closes when its request leaves pending some other way. The
    /// opener calls it before it reads the pending request, so a request that leaves after that is heard.
    func follow() {
        guard let coordinator = coordinator(), ObjectIdentifier(coordinator) != followedID else { return }
        followedID = ObjectIdentifier(coordinator)
        leftSubscription = coordinator.left
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.requestLeft(event.id, why: event.left, source: event.source) }
            }
    }

    /// A request's sheet is about to open. From now until it closes, its gram fields keep their decimals, and the router
    /// is followed to hear it close.
    func begin(_ pending: PendingAIRequest) {
        // The last request's sheet closed, but the router hasn't said so here yet.
        if active != nil {
            sheetClosed()
        }
        let id = pending.request.id
        active = Active(pending: pending)
        gramFormatter = Self.makeGramFormatter()
        routerSubscription = router()?.mainModalScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] screen in
                MainActor.assumeIsolated { self?.modalChanged(to: screen, for: id) }
            }
        debug(.service, "AI requests: opening the Treatments sheet for \(id)")
    }

    static func makeGramFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumIntegerDigits = 3
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }

    // MARK: The sheet

    /// The Treatments sheet appeared. A request's sheet is filled in with its carbs, fat, protein and note once the
    /// wearer's limits have loaded, and `recalculate` then works out the forecast and the recommendation for them. The
    /// bolus and the time stay as the sheet has them. A sheet that comes back from under a cover isn't filled in again.
    func sheetAppeared(state: Treatments.StateModel, recalculate: @escaping () -> Void) {
        guard var active, !active.appeared, !active.leftElsewhere else { return }
        active.appeared = true
        self.active = active
        fillWhenLimitsLoad(state, id: active.pending.request.id, recalculate: recalculate)
    }

    /// The wearer pressed the sheet's Log button. On a request's sheet, the iPhone claims the request, and the session
    /// watches what comes of the submit (see `Submission`). If the claim fails, the request was taken elsewhere: the
    /// sheet's entry goes ahead as the wearer's own, and nothing more is done for the request.
    func willSubmit(from state: Treatments.StateModel) {
        guard var active, active.appeared, !active.leftElsewhere, active.submission == nil,
              let coordinator = coordinator()
        else { return }
        // Nothing to log or give: the sheet only closes, which declines the request.
        guard state.carbs > 0 || state.fat > 0 || state.protein > 0 || state.amount > 0 else { return }

        let id = active.pending.request.id
        let claim = Task { await coordinator.claim(id: id, on: .phone) }
        let submission = Submission(id: id, state: state, claim: claim, coordinator: coordinator)
        let key = ObjectIdentifier(submission)
        watched[key] = submission
        submission.onEnd = { [weak self] in self?.watched[key] = nil }
        // Watched from now, before Face ID or the pump can answer.
        if submission.amount > 0 {
            submission.watchState()
            if !submission.isExternal, let signals = bolusSignals() {
                submission.watch(signals)
            }
            submission.giveUp(at: deadline(Self.outcomeWait))
        }
        active.submission = submission
        self.active = active
        Task { [weak submission] in
            if await claim.value == false {
                debug(.service, "AI requests: the Treatments sheet couldn't claim \(id), so it reports nothing")
                submission?.stop()
            }
        }
    }

    /// The Treatments sheet disappeared. It's closed only if the router no longer shows it; otherwise something covers
    /// it, and it comes back.
    func sheetDisappeared() {
        guard let active, active.appeared, router()?.mainModalScreen.value != .treatmentView else { return }
        sheetClosed()
    }

    // MARK: Filling in

    /// The sheet caps carbs, fat and protein at the wearer's limits, which are 0 until its settings have loaded, so the
    /// request waits for them.
    private func fillWhenLimitsLoad(_ state: Treatments.StateModel, id: String, recalculate: @escaping () -> Void) {
        guard let active, active.pending.request.id == id, active.appeared, !active.filled, !active.leftElsewhere
        else { return }
        guard state.maxCarbs > 0 else {
            withObservationTracking {
                _ = state.maxCarbs
            } onChange: { [weak self, weak state] in
                // It's called as the value is about to change, so the value is read again once it has.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let state else { return }
                        self.fillWhenLimitsLoad(state, id: id, recalculate: recalculate)
                    }
                }
            }
            return
        }
        let request = active.pending.request
        state.carbs = request.carbs
        state.fat = request.fat
        state.protein = request.protein
        state.note = request.note
        self.active?.filled = true
        debug(.service, "AI requests: filled in the Treatments sheet for \(id)")
        recalculate()
    }

    // MARK: Closing

    /// The router shows `screen`. Once it has shown the request's sheet, anything else means the sheet closed: upstream's
    /// `hideModal()` and the wearer's swipe both take it to `nil`.
    private func modalChanged(to screen: Screen?, for id: String) {
        guard var active, active.pending.request.id == id else { return }
        if screen == .treatmentView {
            active.shown = true
            self.active = active
        } else if active.shown {
            sheetClosed()
        }
    }

    /// The request's sheet closed. A submit goes on being watched until its outcome is known; without one, the wearer
    /// declined. A request that left pending some other way gets nothing.
    private func sheetClosed() {
        guard let active else { return }
        self.active = nil
        gramFormatter = nil
        routerSubscription = nil
        guard !active.leftElsewhere else { return }
        if let submission = active.submission {
            submission.sheetClosed()
        } else if let coordinator = coordinator() {
            let id = active.pending.request.id
            Task { await coordinator.close(id: id, on: .phone, dismissed: false) }
        }
    }

    /// The request left pending while its sheet was up, other than by this sheet claiming it. The sheet closes without
    /// reporting anything, and a notice says why.
    private func requestLeft(_ id: String, why left: AIRequestLeft, source: String) {
        guard var active, active.pending.request.id == id, !active.leftElsewhere, left != .claimed(.phone) else { return }
        active.leftElsewhere = true
        active.submission?.stop()
        self.active = active
        debug(.service, "AI requests: \(id) left pending with its Treatments sheet up, so the sheet closes")

        postNotice(for: active.pending, left: left, source: source)
        if let router = router(), router.mainModalScreen.value == .treatmentView {
            // The router following it closes the session.
            router.mainModalScreen.send(nil)
        } else {
            sheetClosed()
        }
    }

    private func postNotice(for pending: PendingAIRequest, left: AIRequestLeft, source: String) {
        let content = UNMutableNotificationContent()
        content.title = AIRequestLeftText.headline(for: left, source: source).headline
        content.body = pending.prompt.title
        content.categoryIdentifier = AIRequestIdentifiers.categoryNotice
        content.threadIdentifier = AIRequestIdentifiers.threadID
        // No trigger: it's delivered right away.
        notifications().add(UNNotificationRequest(
            identifier: "\(AIRequestIdentifiers.resultNotificationSlot)-\(pending.request.id)",
            content: content,
            trigger: nil
        ))
    }
}

// MARK: - Submission

/// What the wearer submitted on a request's sheet, the iPhone's claim on the request, and what came of it, read from the
/// sheet's own state:
/// - Face ID passed when the sheet's `isAwaitingDeterminationResult` turns true after Log. Upstream sets it right after
///   the unlock, for a pump bolus and for external insulin alike, and before then only for a meal with no insulin.
/// - Face ID failed or was canceled when `showDeterminationFailureAlert` turns true before that. Nothing was given.
/// - Only after Face ID passed, the pump starting the bolus (progress `0`) or failing it counts. A progress `0` before
///   then is another bolus, such as an SMB. A failure counts over a start.
/// - External insulin is logged once Face ID passed.
///
/// The outcome is reported once the sheet has closed and it's known, or when `outcomeWait` passes if it's known by
/// then. An outcome still unknown then isn't reported, so the service says Trio didn't confirm what happened.
@MainActor private final class Submission {
    let id: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let amount: Decimal
    let isExternal: Bool
    /// Called once, when the submit has been reported or given up.
    var onEnd: (() -> Void)?

    /// Whether the iPhone claimed the request.
    private let claim: Task<Bool, Never>
    private let coordinator: AIRequestCoordinator
    /// The sheet's state model, which upstream's own task holds until it's done, after the sheet has closed too.
    private let state: Treatments.StateModel

    private var faceIDPassed = false
    private var faceIDFailed = false
    private var bolusStarted = false
    private var bolusFailure: String?
    private var sheetIsClosed = false
    private var ended = false
    private var roundBolus: (Decimal) -> Decimal = { $0 }
    private var signals: AIRequestBolusSignals?
    private var watching: Set<AnyCancellable> = []

    init(id: String, state: Treatments.StateModel, claim: Task<Bool, Never>, coordinator: AIRequestCoordinator) {
        self.id = id
        carbs = state.carbs
        fat = state.fat
        protein = state.protein
        amount = state.amount
        isExternal = state.externalInsulin
        self.state = state
        self.claim = claim
        self.coordinator = coordinator
    }

    /// What the sheet logged and gave, or `nil` while it isn't known.
    private var outcome: AIRequestPhoneResult? {
        func result(_ bolus: AIRequestPhoneBolus, units: Decimal = 0) -> AIRequestPhoneResult {
            AIRequestPhoneResult(carbs: carbs, fat: fat, protein: protein, units: units, bolus: bolus)
        }
        if amount <= 0 { return result(.none) }
        if faceIDFailed { return result(.notStarted) }
        guard faceIDPassed else { return nil }
        if isExternal { return result(.external, units: amount) }
        if let bolusFailure { return result(.failed(reason: bolusFailure)) }
        // The units the pump gives for the amount.
        if bolusStarted { return result(.started, units: roundBolus(amount)) }
        return nil
    }

    /// Follows Face ID through the sheet's state.
    func watchState() {
        guard !ended else { return }
        withObservationTracking {
            _ = state.isAwaitingDeterminationResult
            _ = state.showDeterminationFailureAlert
        } onChange: { [weak self] in
            // It's called as a value is about to change, so the values are read again once they have.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.stateChanged() }
            }
        }
    }

    /// Follows the pump. Its progress's current value is from before Log, so it doesn't count.
    func watch(_ signals: AIRequestBolusSignals) {
        self.signals = signals
        roundBolus = signals.roundBolus
        let lastErrorText = signals.lastErrorText
        signals.progress
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard progress == 0 else { return }
                MainActor.assumeIsolated { self?.pumpStartedABolus() }
            }
            .store(in: &watching)
        signals.failures
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.pumpFailedABolus(lastErrorText() ?? AIRequestTreatmentsSession.bolusFailedReason)
                }
            }
            .store(in: &watching)
    }

    /// When the outcome still isn't known at `deadline`, nothing is reported.
    func giveUp(at deadline: AnyPublisher<Void, Never>) {
        deadline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.deadlinePassed() }
            }
            .store(in: &watching)
    }

    func sheetClosed() {
        sheetIsClosed = true
        reportIfKnown()
    }

    /// Stops watching without reporting: the request was taken elsewhere.
    func stop() {
        end()
    }

    private func stateChanged() {
        guard !ended else { return }
        if !faceIDPassed, !faceIDFailed {
            if state.isAwaitingDeterminationResult {
                faceIDPassed = true
            } else if state.showDeterminationFailureAlert {
                faceIDFailed = true
            }
        }
        reportIfKnown()
        watchState()
    }

    private func pumpStartedABolus() {
        guard faceIDPassed, !ended else { return }
        bolusStarted = true
        reportIfKnown()
    }

    private func pumpFailedABolus(_ reason: String) {
        guard faceIDPassed, !ended else { return }
        bolusFailure = reason
        reportIfKnown()
    }

    private func deadlinePassed() {
        guard !ended else { return }
        if let outcome {
            report(outcome)
        } else {
            debug(.service, "AI requests: what the Treatments sheet did for \(id) isn't known, so it reports nothing")
            end()
        }
    }

    private func reportIfKnown() {
        guard !ended, sheetIsClosed, let outcome else { return }
        report(outcome)
    }

    private func report(_ result: AIRequestPhoneResult) {
        end()
        let claim = claim
        let coordinator = coordinator
        let id = id
        Task {
            guard await claim.value else { return }
            await coordinator.reportPhoneResult(id: id, result)
        }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        watching.removeAll()
        signals?.stop()
        signals = nil
        onEnd?()
        onEnd = nil
    }
}

extension View {
    /// Lets a request's Treatments sheet be filled in when it appears, and heard when it disappears. A sheet the wearer
    /// opened themselves is left alone.
    func aiRequestTreatments(state: Treatments.StateModel, recalculate: @escaping () -> Void) -> some View {
        modifier(AIRequestTreatmentsModifier(state: state, recalculate: recalculate))
    }
}

private struct AIRequestTreatmentsModifier: ViewModifier {
    let state: Treatments.StateModel
    let recalculate: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                AIRequestTreatmentsSession.shared.sheetAppeared(state: state, recalculate: recalculate)
            }
            .onDisappear {
                AIRequestTreatmentsSession.shared.sheetDisappeared()
            }
    }
}
