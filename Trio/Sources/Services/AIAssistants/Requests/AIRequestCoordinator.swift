import Combine
import Foundation

/// Where the wearer answered the pending request.
enum AIRequestAnswerSource: Equatable {
    /// The watch's signed answer, sent to the phone directly or through the service.
    case watch(AIRequestAnswer)
    /// The phone backup, after Face ID or the passcode, for the request it showed.
    case phone(AIRequestDecision, id: String)
}

/// The one owner of the request waiting for the wearer's answer. It asks on the watch or the phone,
/// replaces, expires and withdraws requests, and carries out the answer, reporting each state to where the
/// request came from.
///
/// A request is reported final once: only the pending request, after it's taken out of pending, or a
/// request seen for the first time gets a final report. A repeated ID gets that first final report, or
/// its pending report, again. Each first final report also sends the request's `outcomes`.
actor AIRequestCoordinator {
    enum AnswerOutcome: Equatable {
        /// The answer was accepted, and the request carried out or declined.
        case acted
        /// No request is pending or it has expired, the answer is for another request, or the watch's answer
        /// wasn't made while this one was pending.
        case ignoredNotPending
        /// The watch's answer isn't signed with the current key. The request stays pending.
        case rejectedSignature
        /// The watch's answer is signed for other amounts than the ones shown. The request stays pending.
        case rejectedValues
    }

    /// The request waiting for an answer, if any.
    nonisolated let current: CurrentValueSubject<PendingAIRequest?, Never>
    /// How each request ended, sent once per request, when its first final report is saved. A repeated ID's report
    /// sent again isn't an outcome, and a request Trio stopped carrying out has one when a launch reports it.
    nonisolated let outcomes: PassthroughSubject<AIRequestOutcome, Never>

    private let seen: AIRequestSeenStore
    private let pendingFileURL: URL
    /// Every final report sent in the last `finalReportRetention`, kept next to the pending file.
    private let finalReportsURL: URL
    /// The approval being carried out, kept next to the pending file until its final report.
    private let carryOutMarkerURL: URL
    /// The key the watch signs its answers with.
    private let keys: AIRequestKeyStore
    private let preferences: () -> AIAssistantsPreferences
    private let treatments: AIRequestTreatments
    private let watch: AIRequestWatchDelivery
    private let phoneBackup: AIRequestPhoneBackupScheduling
    private let reporters: [AIRequestChannel: AIRequestReporter]
    private let now: () -> Date

    /// Expires the pending request at its `expiresAt`.
    private var expiryCheck: Task<Void, Never>?
    /// The latest approval being carried out. Each one waits for the one before it, so a bolus is checked
    /// against every bolus approved before it.
    private var carryingOut: Task<Void, Never>?
    /// The approval being carried out. It's also on disk at `carryOutMarkerURL` until its final report, unless a
    /// leftover marker that can't be read yet holds the file.
    private var carryOutMarker: AIRequestCarryOutMarker?
    /// The marker of the approval Trio was carrying out when it stopped, read from disk at launch, until it's
    /// reported. One that can't be read yet stays `.unreadable`, and is read again before it's needed.
    private var leftoverCarryOut: AIRequestCarryOutMarker.Reading = .absent
    /// Whether the pending request, the final reports and the carry-out marker were read from disk.
    private var loaded = false
    /// The final reports on record, oldest first, so a repeated ID gets the same report again.
    private var finalReports: [FinalReport] = []
    /// As long as the seen store keeps an ID.
    private static let finalReportRetention: TimeInterval = 24 * 60 * 60
    /// How far before `createdAt` a watch answer may be signed: the watch's clock against the service's.
    private static let answerClockSkew: TimeInterval = 60
    /// The longest a request is asked for, whatever `expiresAt` the service sent.
    private static let maxLifetime: TimeInterval = 5 * 60
    /// Sent when the wearer has turned meal requests off.
    private static let mealRequestsOffReason = "Meal requests are off in Trio"
    /// Sent when a dose has no loop run from the last 30 minutes, so its insulin on board isn't known.
    private static let noRecentLoopReason = "Trio hasn't looped in the last 30 minutes"
    /// Sent when carbs were logged after the request arrived, so its dose didn't count them.
    private static let carbsLoggedSinceArrivalReason = "Carbs were logged after this request arrived"
    /// Sent when Trio's calculator gives 0 U at approval for a request shown with a dose.
    private static let noLongerSuggestedReason = "Trio no longer suggests insulin for this meal"
    /// Sent at launch for an approval Trio stopped carrying out before it started the bolus.
    private static let stoppedReason = "Trio stopped before it finished"
    /// Sent at launch for an approval Trio stopped carrying out while it started the bolus.
    private static let stoppedWhileEnactingReason = "Trio stopped while starting the bolus. It may have been given"

    private struct FinalReport: Codable {
        let id: String
        let reportedAt: Date
        let report: AIRequestReport
    }

    init(
        seen: AIRequestSeenStore,
        pendingFileURL: URL,
        keys: AIRequestKeyStore,
        preferences: @escaping () -> AIAssistantsPreferences,
        treatments: AIRequestTreatments,
        watch: AIRequestWatchDelivery,
        phoneBackup: AIRequestPhoneBackupScheduling,
        reporters: [AIRequestChannel: AIRequestReporter],
        now: @escaping () -> Date = Date.init
    ) {
        self.seen = seen
        self.pendingFileURL = pendingFileURL
        finalReportsURL = pendingFileURL.deletingLastPathComponent().appendingPathComponent("final-reports.json")
        carryOutMarkerURL = pendingFileURL.deletingLastPathComponent().appendingPathComponent("carrying-out.json")
        self.keys = keys
        self.preferences = preferences
        self.treatments = treatments
        self.watch = watch
        self.phoneBackup = phoneBackup
        self.reporters = reporters
        self.now = now
        current = CurrentValueSubject(nil)
        outcomes = PassthroughSubject()
    }

    deinit {
        expiryCheck?.cancel()
    }

    /// Reports the approval Trio stopped carrying out, if it did. Then watches the request that was pending when Trio
    /// quit, and expires it if its time is up. Its phone backup was scheduled with the system, so it isn't scheduled
    /// again.
    func start() async {
        ensureLoaded()
        await reportStoppedCarryOut()
        if let pending = current.value {
            scheduleExpiryCheck(at: pending.request.expiresAt)
        }
        await expireIfDue()
    }

    func receive(_ request: AIMealRequest, via channel: AIRequestChannel) async {
        ensureLoaded()
        guard let sighting = await observe(request.id, via: channel) else { return }
        if case let .seen(outcome) = sighting {
            // A repeat is never asked again.
            await reportRepeat(of: outcome, for: request.id, via: channel)
            return
        }
        let request = withLifetimeCapped(request)
        let receivedAt = now()
        if receivedAt >= request.expiresAt {
            await reportFinal(AIRequestOutcome(.expired, request: request), via: channel)
            return
        }
        // The test requests are made on the iPhone, so they're asked about either way.
        if channel == .service, !preferences().allowsMealRequests {
            let refused = AIRequestReport.failed(reason: Self.mealRequestsOffReason, carbsLogged: false)
            await reportFinal(AIRequestOutcome(refused, request: request), via: channel)
            return
        }
        if let reason = limitFailure(for: request) {
            let refused = AIRequestReport.failed(reason: reason, carbsLogged: false)
            await reportFinal(AIRequestOutcome(refused, request: request), via: channel)
            return
        }

        let dose = await treatments.dose(forCarbs: request.carbs)
        let units = Self.shownUnits(dose.units)
        // The bolus checks run now as well as at approval: a dose they'd refuse isn't asked about, and the assistant
        // hears why.
        if let reason = await bolusFailure(units: units, iobAsOf: dose.iobAsOf) {
            let refused = AIRequestReport.failed(reason: reason, carbsLogged: false)
            await reportFinal(AIRequestOutcome(refused, request: request), via: channel)
            return
        }
        let display = await treatments.display(for: request, units: units)

        // Nothing suspends from here to the reports, so no other call sees the swap half done.
        let replaced = takePending()
        let preferences = self.preferences()
        let askedOn: AIRequestAskedOn = watch.isWatchAvailable ? .watch : .phone
        let shown = AIRequestShown(carbs: request.carbs, fat: request.fat, protein: request.protein, units: units)
        let prompt = AIRequestPrompt(
            id: request.id,
            source: request.source,
            description: request.description,
            shown: shown,
            title: display.title,
            body: display.body,
            expiresAt: request.expiresAt,
            approvalStyle: preferences.approvalStyle,
            answerRoute: preferences.answerRoute,
            answerToken: nil,
            answerURL: nil
        )
        let phoneDelay = askedOn == .phone ? 0 : preferences.phoneBackupDelay
        let pending = PendingAIRequest(
            request: request,
            channel: channel,
            prompt: prompt,
            askedOn: askedOn,
            units: units,
            receivedAt: receivedAt,
            iobAsOf: dose.iobAsOf,
            phoneAskAt: now().addingTimeInterval(phoneDelay)
        )
        current.send(pending)
        savePending(pending)
        scheduleExpiryCheck(at: request.expiresAt)
        phoneBackup.schedule(prompt, after: phoneDelay)
        if channel == .local {
            // The service's requests reach the watch by the service's push.
            watch.deliver(prompt)
        }
        debug(.service, "AI requests: \(request.id) is pending, asked on the \(askedOn.rawValue)")

        if let replaced {
            await reportFinal(AIRequestOutcome(.replaced, pending: replaced), via: replaced.channel)
        }
        await reporters[channel]?.report(
            .pending(
                askedOn: askedOn,
                approvalStyle: prompt.approvalStyle,
                answerRoute: prompt.answerRoute,
                shown: shown,
                display: display
            ),
            for: request.id
        )
    }

    /// Withdraws a request its assistant cancelled. `request` is set when the inbox lists a withdrawn
    /// request: one Trio never saw is marked seen, so it's never asked later.
    func withdraw(id: String, request: AIMealRequest?, via channel: AIRequestChannel) async {
        ensureLoaded()
        if let pending = takePending(id: id) {
            await reportFinal(AIRequestOutcome(.withdrawn, pending: pending), via: pending.channel)
            return
        }
        guard let request else {
            let resent = await resendFinalReport(for: id, via: channel)
            if !resent {
                debug(.service, "AI requests: \(id) was withdrawn, but it isn't pending")
            }
            return
        }
        // A request Trio already handled keeps its outcome.
        switch await observe(id, via: channel) {
        case .new?:
            await reportFinal(AIRequestOutcome(.withdrawn, request: request), via: channel)
        case let .seen(outcome)?:
            await reportRepeat(of: outcome, for: id, via: channel)
        case nil:
            return
        }
    }

    /// Expires the pending request if its time is up.
    func expireIfDue() async {
        ensureLoaded()
        guard let pending = current.value, now() >= pending.request.expiresAt else { return }
        _ = takePending()
        await reportFinal(AIRequestOutcome(.expired, pending: pending), via: pending.channel)
    }

    /// Carries out the wearer's answer to the pending request. The first answer accepted takes the request
    /// out of pending, so any later one is ignored. A rejected answer leaves the request pending.
    func answer(_ source: AIRequestAnswerSource) async -> AnswerOutcome {
        ensureLoaded()
        guard let pending = current.value else {
            debug(.service, "AI requests: ignored an answer, no request is pending")
            return .ignoredNotPending
        }
        guard now() < pending.request.expiresAt else {
            debug(.service, "AI requests: ignored an answer to \(pending.request.id), it has expired")
            return .ignoredNotPending
        }
        let answeredID: String
        let decision: AIRequestDecision
        let side: AIRequestAnswerSide
        let declinedOn: AIRequestDeclinedOn
        switch source {
        case let .watch(answer):
            if let outcome = rejection(of: answer, for: pending) { return outcome }
            answeredID = answer.requestId
            decision = answer.decision
            side = .watch
            declinedOn = answer.declinedBy == .dismissed ? .dismissed : .watch
        case let .phone(phoneDecision, id):
            answeredID = id
            decision = phoneDecision
            side = .phone
            declinedOn = .phone
        }

        // Taken before the first await, so an answer that arrives meanwhile finds nothing pending.
        guard let answered = takePending(id: answeredID) else {
            debug(.service, "AI requests: ignored an answer to \(answeredID), \(pending.request.id) is pending")
            return .ignoredNotPending
        }
        switch decision {
        case .approve:
            let previous = carryingOut
            let task = Task {
                await previous?.value
                await self.carryOut(answered, approvedOn: side)
            }
            carryingOut = task
            await task.value
        case .decline:
            let declined = AIRequestOutcome(.declined(on: declinedOn), pending: answered, declinedOn: declinedOn)
            await reportFinal(declined, via: answered.channel)
        }
        return .acted
    }

    // MARK: Answers

    /// Why the watch's answer can't be accepted for the pending request, or `nil` if it can. Only the
    /// request ID is logged, never the MAC.
    private func rejection(of answer: AIRequestAnswer, for pending: PendingAIRequest) -> AnswerOutcome? {
        let id = pending.request.id
        guard answer.requestId == id else {
            debug(.service, "AI requests: ignored an answer to \(answer.requestId), \(id) is pending")
            return .ignoredNotPending
        }
        // The MAC doesn't cover `v`, so only the version it was made for is trusted.
        guard answer.v == 1, let key = keys.current, AIRequestSigner.isValid(answer, key: key) else {
            debug(.service, "AI requests: rejected an answer to \(id), its signature doesn't check out")
            return .rejectedSignature
        }
        guard answer.shown == pending.prompt.shown else {
            debug(.service, "AI requests: rejected an answer to \(id), it doesn't match the amounts shown")
            return .rejectedValues
        }
        // `answeredAt` is the watch's clock and `createdAt` the service's, so the watch may be a little behind.
        // The phone's own clock decides expiry.
        let earliest = pending.request.createdAt.addingTimeInterval(-Self.answerClockSkew)
        guard let answeredAt = try? Date(answer.answeredAt, strategy: Date.ISO8601FormatStyle()),
              answeredAt >= earliest, answeredAt <= pending.request.expiresAt
        else {
            debug(.service, "AI requests: ignored an answer to \(id), it wasn't answered while pending")
            return .ignoredNotPending
        }
        return nil
    }

    /// Carries out an approved request. A marker on disk says how far it got until the final report. Every check runs
    /// again before anything is stored, then the carbs are stored, then exactly the units shown are enacted. A failed
    /// bolus keeps the carbs, because the food was eaten. A dry run stops after the checks.
    private func carryOut(_ pending: PendingAIRequest, approvedOn: AIRequestAnswerSide) async {
        // Before this approval's marker replaces it on disk.
        await reportStoppedCarryOut()
        let units = pending.units
        mark(AIRequestCarryOutMarker(
            id: pending.request.id,
            channel: pending.channel,
            title: pending.prompt.title,
            source: pending.request.source,
            shown: pending.prompt.shown,
            askedOn: pending.askedOn,
            approvedOn: approvedOn,
            stage: .checking
        ))

        if let failure = await approvalFailure(for: pending) {
            await reportApproved(.failed(reason: failure, carbsLogged: false), pending, approvedOn: approvedOn)
            return
        }
        if pending.request.testKind == .dryRun {
            await reportApproved(.dryRun(shown: pending.prompt.shown), pending, approvedOn: approvedOn)
            return
        }

        mark(.storingCarbs)
        do {
            try await treatments.storeCarbs(for: pending.request)
        } catch {
            await reportApproved(
                .failed(reason: error.localizedDescription, carbsLogged: false),
                pending,
                approvedOn: approvedOn
            )
            return
        }

        guard units > 0 else {
            await reportApproved(.logged(shown: pending.prompt.shown), pending, approvedOn: approvedOn)
            return
        }
        mark(.enacting)
        if let reason = await treatments.enactBolus(units) {
            await reportApproved(.failed(reason: reason, carbsLogged: true), pending, approvedOn: approvedOn)
        } else {
            await reportApproved(.delivering(shown: pending.prompt.shown), pending, approvedOn: approvedOn)
        }
    }

    /// Why the approved request can't be carried out now, or `nil` if it can: its amounts are over the limits, carbs
    /// were logged after it arrived, Trio's calculator now gives 0 U for a dose it showed, or the bolus checks refuse
    /// the units shown. A lower dose than shown still gives the units shown, which the wearer approved.
    private func approvalFailure(for pending: PendingAIRequest) async -> String? {
        if let reason = limitFailure(for: pending.request) { return reason }
        // A pending file from before Trio recorded `receivedAt` has the service's `createdAt` instead.
        if await treatments.carbsLogged(after: pending.receivedAt ?? pending.request.createdAt) {
            return Self.carbsLoggedSinceArrivalReason
        }
        if pending.units > 0 {
            let dose = await treatments.dose(forCarbs: pending.request.carbs)
            if Self.shownUnits(dose.units) <= 0 { return Self.noLongerSuggestedReason }
        }
        // The units shown were worked out on the arrival's loop run, so insulin is counted from that run.
        return await bolusFailure(units: pending.units, iobAsOf: pending.iobAsOf)
    }

    /// Why Trio can't give `units` now, or `nil` if it can. Only insulin given after the loop run the dose was worked
    /// out on counts as recent: the dose already took the rest into account. A dose without a recent loop run assumed
    /// no insulin on board, so it's refused. A 0 U dose has no bolus to check.
    private func bolusFailure(units: Decimal, iobAsOf: Date?) async -> String? {
        guard units > 0 else { return nil }
        guard let iobAsOf else { return Self.noRecentLoopReason }
        return await treatments.checkBolus(units, since: iobAsOf)
    }

    /// The dose floored to the hundredths that `shown` has, so what's delivered is the number shown.
    private static func shownUnits(_ dose: Decimal) -> Decimal {
        var dose = dose
        var units = Decimal()
        NSDecimalRound(&units, &dose, 2, .down)
        return units
    }

    // MARK: Carry-out marker

    /// Saves a new marker for the approval being carried out. While a leftover marker can't be read yet, the new one
    /// is kept in memory only, so it isn't written over the leftover.
    private func mark(_ marker: AIRequestCarryOutMarker) {
        carryOutMarker = marker
        guard leftoverCarryOut == .absent else {
            debug(.service, "AI requests: kept \(marker.id)'s carry-out marker in memory, an older one can't be read yet")
            return
        }
        marker.save(to: carryOutMarkerURL)
    }

    /// Moves the approval's marker on to `stage`.
    private func mark(_ stage: AIRequestCarryOutMarker.Stage) {
        guard var marker = carryOutMarker else { return }
        marker.stage = stage
        mark(marker)
    }

    /// Removes the marker file if the marker in it is for `id`. It's read from disk, so the final report of another
    /// request, such as one replaced while this approval is carried out, leaves it, and so does a leftover marker
    /// that can't be read yet.
    private func removeCarryOutMarker(for id: String) {
        if carryOutMarker?.id == id {
            carryOutMarker = nil
        }
        guard case let .found(marker) = AIRequestCarryOutMarker.read(from: carryOutMarkerURL), marker.id == id
        else { return }
        AIRequestCarryOutMarker.remove(at: carryOutMarkerURL)
    }

    /// Reports the approval Trio stopped carrying out, once, if a launch found its marker. Once the carbs' save had
    /// started, they're counted as logged. A request whose final report is on record was reported before Trio
    /// stopped, so its marker is only removed. A marker that couldn't be read is read again first: no approval
    /// writes over it meanwhile, so the file is still the one Trio left.
    private func reportStoppedCarryOut() async {
        if leftoverCarryOut == .unreadable {
            leftoverCarryOut = AIRequestCarryOutMarker.read(from: carryOutMarkerURL)
        }
        guard case let .found(stopped) = leftoverCarryOut else { return }
        leftoverCarryOut = .absent
        if finalReports.contains(where: { $0.id == stopped.id }) {
            removeCarryOutMarker(for: stopped.id)
            return
        }
        let reason = stopped.stage == .enacting ? Self.stoppedWhileEnactingReason : Self.stoppedReason
        debug(.service, "AI requests: Trio stopped while carrying out \(stopped.id), at \(stopped.stage.rawValue)")
        let failed = AIRequestReport.failed(reason: reason, carbsLogged: stopped.stage != .checking)
        await reportFinal(AIRequestOutcome(failed, stopped: stopped), via: stopped.channel)
    }

    // MARK: Requests

    /// Records the ID as seen. Returns `nil` when the request is dropped: it has no ID, or the ID
    /// couldn't be saved, which is reported as a failure.
    private func observe(_ id: String, via channel: AIRequestChannel) async -> AIRequestSeenStore.Sighting? {
        do {
            return try seen.observe(id)
        } catch AIRequestSeenStore.SeenError.missingID {
            debug(.service, "AI requests: dropped a request without an ID")
            return nil
        } catch {
            // Without the saved ID, a relaunch couldn't tell a repeat of this request from a new one.
            await reporters[channel]?.report(
                .failed(reason: "Trio couldn't save the request ID", carbsLogged: false),
                for: id
            )
            return nil
        }
    }

    /// The reason a request's amounts can't be logged, if there is one: one is below 0, or over the wearer's max
    /// carbs, fat or protein.
    private func limitFailure(for request: AIMealRequest) -> String? {
        if request.carbs < 0 || request.fat < 0 || request.protein < 0 { return "Invalid amounts" }
        let limits = treatments.limits
        if request.carbs > limits.maxCarbs { return "Over your max carbs (\(limits.maxCarbs) g)" }
        if request.fat > limits.maxFat { return "Over your max fat (\(limits.maxFat) g)" }
        if request.protein > limits.maxProtein { return "Over your max protein (\(limits.maxProtein) g)" }
        return nil
    }

    /// The request with an `expiresAt` no later than `maxLifetime` after it was made, or after now: the service's
    /// clock may be ahead of the phone's.
    private func withLifetimeCapped(_ request: AIMealRequest) -> AIMealRequest {
        let expiresAt = min(
            request.expiresAt,
            request.createdAt.addingTimeInterval(Self.maxLifetime),
            now().addingTimeInterval(Self.maxLifetime)
        )
        guard expiresAt < request.expiresAt else { return request }
        return AIMealRequest(
            id: request.id,
            source: request.source,
            description: request.description,
            carbs: request.carbs,
            fat: request.fat,
            protein: request.protein,
            createdAt: request.createdAt,
            expiresAt: expiresAt,
            testKind: request.testKind
        )
    }

    /// Takes the pending request out of pending, so nothing else can replace, expire, withdraw or answer it.
    private func takePending() -> PendingAIRequest? {
        guard let pending = current.value else { return nil }
        expiryCheck?.cancel()
        expiryCheck = nil
        current.send(nil)
        deletePendingFile()
        phoneBackup.cancel(id: pending.request.id)
        watch.withdraw(id: pending.request.id)
        return pending
    }

    /// Takes the pending request out of pending only if it has this ID, so another request is never answered
    /// or withdrawn in its place.
    private func takePending(id: String) -> PendingAIRequest? {
        guard current.value?.request.id == id else { return nil }
        return takePending()
    }

    private func scheduleExpiryCheck(at date: Date) {
        expiryCheck?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        expiryCheck = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // the request left pending first
            }
            await self?.expireIfDue()
        }
    }

    // MARK: Reports

    /// Saves the request's first final report, sends its `outcomes`, and reports it to where the request came from.
    private func reportFinal(_ outcome: AIRequestOutcome, via channel: AIRequestChannel) async {
        let id = outcome.id
        let report = outcome.report
        seen.setOutcome(report.state, for: id)
        saveFinalReport(report, for: id)
        // After the final report is saved, so a launch that finds the marker can tell it was reported.
        removeCarryOutMarker(for: id)
        debug(.service, "AI requests: \(id) is \(report.state.rawValue)")
        // Before the report goes out, which can wait on the network, so the watch and the iPhone hear it at once.
        outcomes.send(outcome)
        await reporters[channel]?.report(report, for: id)
    }

    /// The final report of an approved request: its outcome says where it was approved.
    private func reportApproved(
        _ report: AIRequestReport,
        _ pending: PendingAIRequest,
        approvedOn: AIRequestAnswerSide
    ) async {
        await reportFinal(AIRequestOutcome(report, pending: pending, approvedOn: approvedOn), via: pending.channel)
    }

    /// Answers a repeated ID. A finished request gets its first final report again, and the pending request
    /// its pending report. A request still being received stays silent.
    private func reportRepeat(of outcome: AIRequestState?, for id: String, via channel: AIRequestChannel) async {
        if let outcome {
            let resent = await resendFinalReport(for: id, via: channel)
            if !resent {
                debug(.service, "AI requests: \(id) is already \(outcome.rawValue), but its report isn't on record")
            }
        } else if let pending = current.value, pending.request.id == id {
            await reporters[channel]?.report(Self.pendingReport(for: pending), for: id)
        }
    }

    /// Sends a finished request's first final report again. Returns `false` if none is on record.
    private func resendFinalReport(for id: String, via channel: AIRequestChannel) async -> Bool {
        dropOldFinalReports()
        guard let report = finalReports.first(where: { $0.id == id })?.report else { return false }
        await reporters[channel]?.report(report, for: id)
        return true
    }

    private static func pendingReport(for pending: PendingAIRequest) -> AIRequestReport {
        .pending(
            askedOn: pending.askedOn,
            approvalStyle: pending.prompt.approvalStyle,
            answerRoute: pending.prompt.answerRoute,
            shown: pending.prompt.shown,
            display: AIRequestDisplay(title: pending.prompt.title, body: pending.prompt.body)
        )
    }

    // MARK: Files

    /// Reads the pending request, the final reports and the carry-out marker, once, before the first call uses them,
    /// so the marker read is the one Trio left, not a new approval's. A marker that can't be read yet is read again
    /// by `reportStoppedCarryOut()`.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        finalReports = loadFinalReports()
        dropOldFinalReports()
        leftoverCarryOut = AIRequestCarryOutMarker.read(from: carryOutMarkerURL)
        if let pending = loadPending() {
            current.send(pending)
        }
    }

    private func loadPending() -> PendingAIRequest? {
        guard FileManager.default.fileExists(atPath: pendingFileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(PendingAIRequest.self, from: Data(contentsOf: pendingFileURL))
        } catch {
            debug(.service, "AI requests: pending request file unreadable, dropping it: \(error)")
            deletePendingFile()
            return nil
        }
    }

    private func savePending(_ pending: PendingAIRequest) {
        do {
            try JSONEncoder().encode(pending).write(to: pendingFileURL, options: .atomic)
        } catch {
            debug(.service, "AI requests: couldn't save the pending request: \(error)")
        }
    }

    private func deletePendingFile() {
        do {
            try FileManager.default.removeItem(at: pendingFileURL)
        } catch {
            debug(.service, "AI requests: couldn't delete the pending request file: \(error)")
        }
    }

    private func loadFinalReports() -> [FinalReport] {
        guard FileManager.default.fileExists(atPath: finalReportsURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([FinalReport].self, from: Data(contentsOf: finalReportsURL))
        } catch {
            debug(.service, "AI requests: final reports file unreadable, starting empty: \(error)")
            return []
        }
    }

    private func saveFinalReport(_ report: AIRequestReport, for id: String) {
        dropOldFinalReports()
        finalReports.append(FinalReport(id: id, reportedAt: now(), report: report))
        do {
            try JSONEncoder().encode(finalReports).write(to: finalReportsURL, options: .atomic)
        } catch {
            debug(.service, "AI requests: couldn't save the final reports: \(error)")
        }
    }

    private func dropOldFinalReports() {
        let cutoff = now().addingTimeInterval(-Self.finalReportRetention)
        finalReports.removeAll { $0.reportedAt < cutoff }
    }
}
