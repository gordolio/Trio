import Combine
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// The Treatments sheet that a request opened. It's Trio's own sheet, filled in with the request, and the wearer
/// finishes it like a meal they typed themselves: the sheet's own checks, warnings and Face ID all stay. The session
/// fills the sheet in once the wearer's limits have loaded, keeps the request's decimals in its gram fields, and reports
/// what the sheet did when it closes: what was logged and given if the wearer submitted it, or a decline if they closed
/// it. If the request leaves pending while the sheet is open, as when it was logged on the watch, the session closes the
/// sheet and says why in a notice.
///
/// A Treatments sheet the wearer opens themselves isn't a request's, and the session leaves it alone.
@MainActor final class AIRequestTreatmentsSession {
    static let shared = AIRequestTreatmentsSession()

    /// The formatter of the sheet's carbs, fat and protein fields while a request's sheet is up: up to three whole digits
    /// and two decimals, so the request's 82.5 g stays 82.5 g. It's `nil` otherwise, and the sheet keeps its own.
    private(set) var gramFormatter: NumberFormatter?

    /// The request whose sheet is up, from `begin(_:)` until the sheet disappears.
    var requestID: String? { active?.pending.request.id }

    private let coordinator: () -> AIRequestCoordinator?
    private let router: @MainActor() -> Router?
    private let notifications: () -> AIRequestNotificationScheduling
    private let bolusSignals: @MainActor() -> AIRequestBolusSignals?

    private var active: Active?
    /// The coordinator whose `left` the session follows.
    private var followedID: ObjectIdentifier?
    private var leftSubscription: AnyCancellable?

    /// Sent when a bolus asked for on the sheet failed, and Trio has no error saying why.
    private static let bolusFailedReason = String(
        localized: "Bolus failed",
        comment: "Report reason: the bolus the wearer asked for on the Treatments sheet failed"
    )

    /// A request's sheet, from `begin(_:)` until it disappears.
    private struct Active {
        let pending: PendingAIRequest
        /// The sheet appeared, so its disappearing ends the session.
        var appeared = false
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
        bolusSignals: @escaping @MainActor() -> AIRequestBolusSignals? = { AIRequestBolusSignals.live() }
    ) {
        self.coordinator = coordinator
        self.router = router
        self.notifications = notifications
        self.bolusSignals = bolusSignals
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

    /// A request's sheet is about to open. From now until it disappears, its gram fields keep their decimals.
    func begin(_ pending: PendingAIRequest) {
        // The last request's sheet is still on its way out: it ends first.
        if let previous = active, previous.appeared {
            finish(previous)
        }
        active = Active(pending: pending)
        gramFormatter = Self.makeGramFormatter()
        debug(.service, "AI requests: opening the Treatments sheet for \(pending.request.id)")
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
    /// bolus and the time stay as the sheet has them.
    func sheetAppeared(state: Treatments.StateModel, recalculate: @escaping () -> Void) {
        guard var active, !active.appeared, !active.leftElsewhere else { return }
        active.appeared = true
        self.active = active
        fillWhenLimitsLoad(state, id: active.pending.request.id, recalculate: recalculate)
    }

    /// The Log button's hook: what the sheet is about to log and give.
    func willSubmit(from state: Treatments.StateModel) {
        willSubmit(
            carbs: state.carbs,
            fat: state.fat,
            protein: state.protein,
            amount: state.amount,
            isExternal: state.externalInsulin
        )
    }

    /// The wearer pressed the sheet's Log button. On a request's sheet, the iPhone claims the request, and the session
    /// watches what comes of the bolus until the sheet closes. If the claim fails, the request was taken elsewhere: the
    /// sheet's entry goes ahead as the wearer's own, and nothing more is done for the request.
    func willSubmit(carbs: Decimal, fat: Decimal, protein: Decimal, amount: Decimal, isExternal: Bool) {
        guard var active, active.appeared, !active.leftElsewhere, active.submission == nil,
              let coordinator = coordinator()
        else { return }
        // Nothing to log or give: the sheet only closes, which declines the request.
        guard carbs > 0 || fat > 0 || protein > 0 || amount > 0 else { return }

        let id = active.pending.request.id
        let submission = Submission(
            carbs: carbs,
            fat: fat,
            protein: protein,
            amount: amount,
            isExternal: isExternal,
            claim: Task { await coordinator.claim(id: id, on: .phone) }
        )
        // Watched from now, before the pump can hear of the bolus.
        if amount > 0, !isExternal, let signals = bolusSignals() {
            submission.watch(signals)
        }
        active.submission = submission
        self.active = active
    }

    /// The Treatments sheet disappeared. A request's sheet reports what it did, unless its request left pending some
    /// other way, and the gram fields go back to whole grams.
    func sheetDisappeared() {
        guard let active, active.appeared else { return }
        self.active = nil
        gramFormatter = nil
        finish(active)
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

    // MARK: Ending

    /// Reports what the sheet did: the bolus as it stood when the sheet closed, once the claim has gone through, or a
    /// decline if the wearer closed it without submitting. A request that left pending some other way gets nothing.
    private func finish(_ active: Active) {
        guard !active.leftElsewhere, let coordinator = coordinator() else { return }
        let id = active.pending.request.id
        guard let submission = active.submission else {
            Task { await coordinator.close(id: id, on: .phone, dismissed: false) }
            return
        }
        let result = submission.result
        submission.stopWatching()
        Task {
            guard await submission.claim.value else {
                debug(.service, "AI requests: the Treatments sheet couldn't claim \(id), so it reports nothing")
                return
            }
            await coordinator.reportPhoneResult(id: id, result)
        }
    }

    /// The request left pending while its sheet was up, other than by this sheet claiming it. The sheet closes without
    /// reporting anything, and a notice says why.
    private func requestLeft(_ id: String, why left: AIRequestLeft, source: String) {
        guard var active, active.pending.request.id == id, !active.leftElsewhere, left != .claimed(.phone) else { return }
        active.leftElsewhere = true
        active.submission?.stopWatching()
        self.active = active
        debug(.service, "AI requests: \(id) left pending with its Treatments sheet up, so the sheet closes")

        if let router = router(), router.mainModalScreen.value == .treatmentView {
            router.mainModalScreen.send(nil)
        }
        postNotice(for: active.pending, left: left, source: source)
        // A sheet that never appeared won't disappear to end the session.
        if !active.appeared {
            self.active = nil
            gramFormatter = nil
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

    // MARK: Submission

    /// What the wearer submitted, the iPhone's claim on the request, and what came of the bolus.
    @MainActor private final class Submission {
        let carbs: Decimal
        let fat: Decimal
        let protein: Decimal
        let amount: Decimal
        let isExternal: Bool
        /// Whether the iPhone claimed the request.
        let claim: Task<Bool, Never>

        private var bolusStarted = false
        private var bolusFailure: String?
        /// Kept while the bolus is watched.
        private var signals: AIRequestBolusSignals?
        private var watching: Set<AnyCancellable> = []

        init(carbs: Decimal, fat: Decimal, protein: Decimal, amount: Decimal, isExternal: Bool, claim: Task<Bool, Never>) {
            self.carbs = carbs
            self.fat = fat
            self.protein = protein
            self.amount = amount
            self.isExternal = isExternal
            self.claim = claim
        }

        /// What the sheet logged and gave, as far as is known now. A bolus that neither started nor failed by now wasn't
        /// started, as when Face ID was canceled.
        var result: AIRequestPhoneResult {
            let bolus: AIRequestPhoneBolus
            if amount <= 0 {
                bolus = .none
            } else if isExternal {
                bolus = .external
            } else if let bolusFailure {
                bolus = .failed(reason: bolusFailure)
            } else if bolusStarted {
                bolus = .started
            } else {
                bolus = .notStarted
            }
            return AIRequestPhoneResult(carbs: carbs, fat: fat, protein: protein, units: amount, bolus: bolus)
        }

        /// The pump accepting a bolus sends the progress `0`. Its current value is from before the submit, so it doesn't
        /// count. A failure names Trio's last error.
        func watch(_ signals: AIRequestBolusSignals) {
            self.signals = signals
            let lastErrorText = signals.lastErrorText
            signals.progress
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] progress in
                    guard progress == 0 else { return }
                    MainActor.assumeIsolated { self?.bolusStarted = true }
                }
                .store(in: &watching)
            signals.failures
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    MainActor.assumeIsolated {
                        self?.bolusFailure = lastErrorText() ?? AIRequestTreatmentsSession.bolusFailedReason
                    }
                }
                .store(in: &watching)
        }

        func stopWatching() {
            watching.removeAll()
            signals = nil
        }
    }
}

/// What Trio's APS manager says about a bolus the wearer asked for on the Treatments sheet.
struct AIRequestBolusSignals {
    /// `APSManager.bolusProgress`. It sends `0` when the pump accepts a bolus.
    let progress: CurrentValueSubject<Decimal?, Never>
    /// Sends for each `BolusFailureObserver.bolusDidFail()`: a bolus asked for by hand failed.
    let failures: AnyPublisher<Void, Never>
    /// The text of `APSManager.lastError`, if there is one.
    let lastErrorText: () -> String?
    /// Whatever has to live while the signals are watched. The broadcaster holds its observers weakly.
    var keepAlive: AnyObject?

    /// Trio's own, or `nil` if its APS manager isn't there.
    @MainActor static func live() -> AIRequestBolusSignals? {
        let resolver = TrioApp.resolver
        guard let apsManager = resolver.resolve(APSManager.self),
              let broadcaster = resolver.resolve(Broadcaster.self)
        else { return nil }
        let relay = BolusFailureRelay()
        broadcaster.register(BolusFailureObserver.self, observer: relay)
        return AIRequestBolusSignals(
            progress: apsManager.bolusProgress,
            failures: relay.failures.eraseToAnyPublisher(),
            lastErrorText: { apsManager.lastError.value?.localizedDescription },
            keepAlive: relay
        )
    }
}

/// Passes the broadcaster's `bolusDidFail()` on as a publisher.
private final class BolusFailureRelay: BolusFailureObserver {
    let failures = PassthroughSubject<Void, Never>()

    func bolusDidFail() {
        failures.send()
    }
}

extension View {
    /// Lets a request's Treatments sheet be filled in when it appears, and report what it did when it disappears. A
    /// sheet the wearer opened themselves is left alone.
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
