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
/// says why in a notice, and a Log pressed on it then logs nothing.
///
/// The sheet is closed when Trio's router no longer shows it, not just when its `onDisappear` runs. A cover shown from
/// inside the sheet, such as the AI food chat, doesn't run it (checked on iOS 26.5 and 27), but the session doesn't rely
/// on that.
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
    private let now: () -> Date

    private var active: Active?
    /// The coordinator whose `left` the session follows.
    private var followedID: ObjectIdentifier?
    private var leftSubscription: AnyCancellable?
    /// Follows the router while a request's sheet is up.
    private var routerSubscription: AnyCancellable?
    /// The submits whose outcome is still watched, which can be after their sheet closed.
    private var watched: [ObjectIdentifier: Submission] = [:]
    /// The last request's sheet to appear. It's kept after the sheet closes, as its Log can still be pressed while it goes.
    private var requestSheet: RequestSheet?
    /// The request whose sheet closed when its submit was refused, before the session heard why it left pending. Its
    /// notice is posted once the session hears.
    private var noticeOwed: PendingAIRequest?

    /// Sent when a bolus asked for on the sheet failed, and Trio has no error saying why. The service passes it to the
    /// assistant, so it's plain English, like the coordinator's reasons.
    fileprivate static let bolusFailedReason = "Bolus failed"

    /// A request's sheet: its state model, weakly, so a sheet the wearer opens later, which has a state model of its
    /// own, is never taken for it.
    private struct RequestSheet {
        weak var state: Treatments.StateModel?
        let requestID: String
    }

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
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.router = router
        self.notifications = notifications
        self.bolusSignals = bolusSignals
        self.deadline = deadline
        self.now = now
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
    /// wearer's settings have loaded, and `recalculate` then works out the forecast and the recommendation for them.
    /// The bolus and the time stay as the sheet has them. It's filled in once: a sheet that appears again isn't filled
    /// in again.
    func sheetAppeared(state: Treatments.StateModel, recalculate: @escaping () -> Void) {
        guard var active, !active.appeared, !active.leftElsewhere else { return }
        active.appeared = true
        self.active = active
        requestSheet = RequestSheet(state: state, requestID: active.pending.request.id)
        fillWhenLimitsLoad(state, id: active.pending.request.id, recalculate: recalculate)
    }

    /// The wearer pressed the sheet's Log button. Returns whether the sheet's submit is refused, so that nothing is
    /// logged or given. A sheet the wearer opened themselves is never refused.
    ///
    /// A request's sheet is refused once its request is no longer the pending one: it was logged on the watch, say, or
    /// a newer request replaced it, maybe a moment ago, before the sheet heard. The sheet closes, and the notice says
    /// why, as when it hears first. A sheet already closing for its request is refused too, and so is a second Log on a
    /// sheet that submitted its request.
    ///
    /// Otherwise, on a request's sheet, the iPhone takes the request at once, through the lock the watch's confirm also
    /// takes it through, so only one device carries it out. If the watch took it first, in the moment before the
    /// request left pending, the submit is refused as above. The iPhone then claims the request, and the session
    /// watches what comes of the submit (see `Submission`). If the claim still fails, as when the request's time ran
    /// out in that moment, the submit goes ahead as the wearer's own, and nothing more is done for the request.
    func refusesSubmit(from state: Treatments.StateModel) -> Bool {
        guard let sheet = requestSheet, sheet.state === state else { return false }
        let id = sheet.requestID
        guard var active, active.pending.request.id == id else {
            // The sheet closed for its request: it was answered here, or it left pending and the notice said so.
            debug(.service, "AI requests: the Treatments sheet of \(id) has closed, so its submit logs nothing")
            return true
        }
        guard !active.leftElsewhere, active.submission == nil else {
            debug(.service, "AI requests: the Treatments sheet of \(id) is closing or submitted, so this submit logs nothing")
            return true
        }
        guard let coordinator = coordinator() else { return false }
        guard coordinator.current.value?.request.id == id else {
            debug(.service, "AI requests: \(id) left pending as its Treatments sheet's Log was pressed, so it logs nothing")
            active.leftElsewhere = true
            self.active = active
            noticeOwed = active.pending
            closeSheet()
            return true
        }
        // Nothing to log or give: the sheet only closes, which declines the request.
        guard state.carbs > 0 || state.fat > 0 || state.protein > 0 || state.amount > 0 else { return false }
        // Taken here, before upstream's submit goes ahead: the claim below reaches the coordinator a moment later, and
        // a watch confirm that reaches it first is refused. A watch confirm that took it first wins instead.
        guard coordinator.take(id, by: .phone) else {
            debug(.service, "AI requests: the watch took \(id) as its Treatments sheet's Log was pressed, so it logs nothing")
            active.leftElsewhere = true
            self.active = active
            noticeOwed = active.pending
            closeSheet()
            return true
        }

        let claim = Task { await coordinator.claim(id: id, on: .phone) }
        let submission = Submission(id: id, state: state, submittedAt: now(), claim: claim, coordinator: coordinator)
        let key = ObjectIdentifier(submission)
        watched[key] = submission
        submission.onEnd = { [weak self] in self?.watched[key] = nil }
        // Watched from now, before Face ID or the pump can answer.
        if submission.amount > 0 {
            submission.watchState()
            if let signals = bolusSignals() {
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
        return false
    }

    /// The Treatments sheet disappeared. It's closed only if the router no longer shows it; otherwise it's still the
    /// request's open sheet.
    func sheetDisappeared() {
        guard let active, active.appeared, router()?.mainModalScreen.value != .treatmentView else { return }
        sheetClosed()
    }

    // MARK: Filling in

    /// The sheet caps carbs, fat and protein at the wearer's limits, which are 0 until its settings have loaded, so the
    /// request waits for them. Its fat and protein entries setting loads with them: with it off, as by default, the sheet
    /// hides fat and protein, so they stay 0. Upstream would still log them, and dose for their carb equivalents.
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
        if state.useFPUconversion {
            state.fat = request.fat
            state.protein = request.protein
        }
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
    /// declined. A request that left pending some other way gets nothing, and so does a sheet that never appeared: on a
    /// cold launch, Main resets the router as it starts, before the sheet can appear. That request keeps waiting, and
    /// the next tap or the next time Trio comes to the front opens it again.
    private func sheetClosed() {
        guard let active else { return }
        self.active = nil
        gramFormatter = nil
        routerSubscription = nil
        guard !active.leftElsewhere else { return }
        guard active.appeared else {
            debug(.service, "AI requests: the Treatments sheet for \(active.pending.request.id) went before it appeared")
            return
        }
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
        if let owed = noticeOwed, owed.request.id == id {
            // Its sheet closed when its submit was refused, before the session heard why.
            noticeOwed = nil
            postNotice(for: owed, left: left, source: source)
            return
        }
        guard var active, active.pending.request.id == id, !active.leftElsewhere, left != .claimed(.phone) else { return }
        active.leftElsewhere = true
        active.submission?.stop()
        self.active = active
        debug(.service, "AI requests: \(id) left pending with its Treatments sheet up, so the sheet closes")

        postNotice(for: active.pending, left: left, source: source)
        closeSheet()
    }

    /// The opener asked for the request's sheet, but couldn't hold the request: its time ran out as the sheet opened,
    /// and the watch holds it. The sheet closes again without answering.
    func notOpened(_ id: String) {
        guard var active, active.pending.request.id == id, !active.leftElsewhere else { return }
        active.leftElsewhere = true
        self.active = active
        debug(.service, "AI requests: \(id)'s time ran out as its Treatments sheet opened, so the sheet closes")
        closeSheet()
    }

    /// Closes the request's sheet. The router following it closes the session; a sheet the router no longer shows is
    /// closed here.
    private func closeSheet() {
        if let router = router(), router.mainModalScreen.value == .treatmentView {
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

/// What the wearer submitted on a request's sheet, the iPhone's claim on the request, and what came of it.
///
/// What the pump took is confirmed from Trio's pump history: the bolus this sheet gave is a stored bolus that the loop
/// didn't give and isn't external, timestamped at or after Log, and its amount is the units reported. External insulin
/// is confirmed the same way, from the external insulin stored at the sheet's time with the sheet's amount, which
/// upstream caps at three times the max bolus. The pump's
/// progress alone never confirms a bolus: an SMB sends it too. It only prompts another look at the history.
///
/// Face ID is followed through the sheet's state:
/// - It passed once `isAwaitingDeterminationResult` turns true after Log. Upstream sets it right after the unlock, for a
///   pump bolus and for external insulin alike, and before then only for a meal with no insulin. Once seen, it stays
///   passed. This sheet's own stored bolus counts as passed too, in case the flag's turn was missed.
/// - It failed or was canceled when `showDeterminationFailureAlert` turns true before it passed. Nothing was given.
///
/// A pump failure counts only after Face ID passed, and only when the pump history, read after the failure, doesn't hold
/// this sheet's bolus. A Face ID failure is checked against the history the same way. This sheet's stored bolus wins
/// over both.
///
/// The outcome is reported once the sheet has closed and it's known. When `outcomeWait` passes, the history is read
/// once more, and an outcome known then is reported whether or not the sheet has closed. An outcome still unknown then
/// isn't reported, so the service says Trio didn't confirm what happened.
@MainActor private final class Submission {
    let id: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let amount: Decimal
    let isExternal: Bool
    /// Called once, when the submit has been reported or given up.
    var onEnd: (() -> Void)?

    /// When the wearer pressed Log.
    private let submittedAt: Date
    /// The time the sheet logs the treatment at, which the wearer can move.
    private let treatmentDate: Date
    /// Whether the iPhone claimed the request.
    private let claim: Task<Bool, Never>
    private let coordinator: AIRequestCoordinator
    /// The sheet's state model, which upstream's own task holds until it's done, after the sheet has closed too.
    private let state: Treatments.StateModel

    private var faceIDPassed = false
    /// Face ID failed, waiting for the pump history to confirm that nothing of this sheet's was given.
    private var faceIDFailureHeard = false
    private var faceIDFailed = false
    /// This sheet's bolus or external insulin, as stored in the pump history.
    private var ownEvent: AIRequestPumpBolusEvent?
    /// A pump failure, waiting for the pump history to confirm that this sheet's bolus isn't there.
    private var failureHeard: String?
    private var bolusFailure: String?
    private var sheetIsClosed = false
    private var ended = false
    private var roundBolus: (Decimal) -> Decimal = { $0 }
    private var signals: AIRequestBolusSignals?
    private var watching: Set<AnyCancellable> = []

    init(
        id: String,
        state: Treatments.StateModel,
        submittedAt: Date,
        claim: Task<Bool, Never>,
        coordinator: AIRequestCoordinator
    ) {
        self.id = id
        carbs = state.carbs
        fat = state.fat
        protein = state.protein
        amount = state.amount
        isExternal = state.externalInsulin
        treatmentDate = state.date
        self.submittedAt = submittedAt
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
        if let ownEvent {
            if isExternal { return result(.external, units: ownEvent.amount ?? amount) }
            // What the pump took, or else what it gives for the amount.
            return result(.started, units: ownEvent.amount ?? roundBolus(amount))
        }
        if let bolusFailure { return result(.failed(reason: bolusFailure)) }
        if faceIDFailed { return result(.notStarted) }
        return nil
    }

    /// Whether `event` is what this sheet gave.
    private func isOwn(_ event: AIRequestPumpBolusEvent) -> Bool {
        guard !event.isSMB else { return false }
        if isExternal {
            // Upstream logs external insulin of at most three times the max bolus.
            guard event.isExternal, event.amount == min(amount, state.maxBolus * 3) else { return false }
            // Stored at the sheet's time, or at the moment it was stored when that time was ahead.
            return abs(event.timestamp.timeIntervalSince(treatmentDate)) <= 1
                || (treatmentDate > submittedAt && event.timestamp >= submittedAt)
        }
        return !event.isExternal && event.timestamp >= submittedAt
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

    /// Follows the pump history, and for a pump bolus the pump's progress and failures.
    func watch(_ signals: AIRequestBolusSignals) {
        self.signals = signals
        roundBolus = signals.roundBolus
        signals.historyUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.readHistory() }
            }
            .store(in: &watching)
        guard !isExternal else { return }
        let lastErrorText = signals.lastErrorText
        // Its current value is from before Log.
        signals.progress
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard progress == 0 else { return }
                MainActor.assumeIsolated { self?.pumpReportedProgress() }
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

    /// When `deadline` sends, the outcome is reported if it's known, and otherwise given up.
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
        if !faceIDPassed, state.isAwaitingDeterminationResult {
            faceIDPassed = true
        } else if !faceIDPassed, !faceIDFailureHeard, state.showDeterminationFailureAlert {
            faceIDFailureHeard = true
            readHistory()
        }
        watchState()
    }

    /// A bolus started, maybe this sheet's: the pump history says.
    private func pumpReportedProgress() {
        guard faceIDPassed, !ended else { return }
        readHistory()
    }

    private func pumpFailedABolus(_ reason: String) {
        guard faceIDPassed, !ended else { return }
        failureHeard = reason
        readHistory()
    }

    /// Reads the pump history from the earlier of Log and the sheet's time. The failures heard before the read are
    /// confirmed by it.
    private func readHistory(then decide: ((Submission) -> Void)? = nil) {
        guard !ended else { return }
        let failure = failureHeard
        let faceIDFailure = faceIDFailureHeard
        guard let boluses = signals?.boluses else {
            historyRead([], confirming: failure, faceIDFailure: faceIDFailure)
            decide?(self)
            return
        }
        let since = min(submittedAt, treatmentDate).addingTimeInterval(-1)
        Task { [weak self] in
            let events = await boluses(since)
            guard let self else { return }
            historyRead(events, confirming: failure, faceIDFailure: faceIDFailure)
            decide?(self)
        }
    }

    private func historyRead(_ events: [AIRequestPumpBolusEvent], confirming failure: String?, faceIDFailure: Bool) {
        guard !ended else { return }
        if ownEvent == nil, let event = events.first(where: isOwn) {
            ownEvent = event
            faceIDPassed = true
        }
        if let failure {
            bolusFailure = failure
        }
        if faceIDFailure {
            faceIDFailed = true
        }
        reportIfKnown()
    }

    private func deadlinePassed() {
        readHistory { submission in
            submission.reportOrGiveUp()
        }
    }

    private func reportOrGiveUp() {
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
