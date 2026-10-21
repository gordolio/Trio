import Combine
import Foundation

/// The one owner of the request waiting for the wearer's answer. It asks on the watch or the phone,
/// replaces, expires and withdraws requests, and carries out the answer, reporting each state to where the
/// request came from.
///
/// The wearer answers on Trio's own screens: the iPhone's Treatments sheet and the watch's Confirm screen. The
/// coordinator knows which of them has the pending request open, which holds its expiry, and lets the first one to
/// confirm claim it. Each time the pending request leaves pending, `left` says why, so the other screen closes.
///
/// A request is reported final once: only the pending request, after it's taken out of pending, or a
/// request seen for the first time gets a final report. A repeated ID gets that first final report, or
/// its pending report, again.
actor AIRequestCoordinator {
    /// The request waiting for an answer, if any.
    nonisolated let current: CurrentValueSubject<PendingAIRequest?, Never>
    /// Why the pending request left pending, with its ID and who asked. It's sent the moment the request leaves, for
    /// any reason, before anything awaits, so a device that has it open hears at once.
    nonisolated let left: PassthroughSubject<(id: String, left: AIRequestLeft, source: String), Never>

    private let seen: AIRequestSeenStore
    private let pendingFileURL: URL
    /// Every final report sent in the last `finalReportRetention`, kept next to the pending file.
    private let finalReportsURL: URL
    /// The approval being carried out, kept next to the pending file until its final report.
    private let carryOutMarkerURL: URL
    private let preferences: () -> AIAssistantsPreferences
    private let treatments: AIRequestTreatments
    private let watch: AIRequestWatchDelivery
    private let phoneBackup: AIRequestPhoneBackupScheduling
    private let reporters: [AIRequestChannel: AIRequestReporter]
    private let now: () -> Date

    /// Expires the pending request at its `expiresAt`.
    private var expiryCheck: Task<Void, Never>?
    /// The latest approval being carried out, and its final report. Each one waits for the one before it, so one
    /// carry-out marker is on disk at a time.
    private var carryingOut: Task<AIRequestReport, Never>?
    /// The approval being carried out. It's also on disk at `carryOutMarkerURL` until its final report, unless a
    /// leftover marker that can't be read yet holds the file.
    private var carryOutMarker: AIRequestCarryOutMarker?
    /// The marker of the approval Trio was carrying out when it stopped, read from disk at launch, until it's
    /// reported. One that can't be read yet stays `.unreadable`, and is read again before it's needed.
    private var leftoverCarryOut: AIRequestCarryOutMarker.Reading = .absent
    /// The request whose backup was postponed, so each request is postponed once. It's kept in memory only: a relaunch
    /// while the request is pending allows one more.
    private var postponedBackupID: String?
    /// The devices that have the pending request open on their screen. It's kept in memory only, so a relaunch drops
    /// the hold they put on its expiry, and it's cleared whenever the request leaves pending.
    private var openOn: Set<AIRequestAnswerSide> = []
    /// The requests a device claimed, until their final report.
    private var claims: [String: Claim] = [:]
    /// Whether the pending request, the final reports and the carry-out marker were read from disk.
    private var loaded = false
    /// The final reports on record, oldest first, so a repeated ID gets the same report again.
    private var finalReports: [FinalReport] = []
    /// As long as the seen store keeps an ID.
    private static let finalReportRetention: TimeInterval = 24 * 60 * 60
    /// The longest a request is asked for, whatever `expiresAt` the service sent.
    private static let maxLifetime: TimeInterval = 5 * 60
    /// How long from the watch opening its approval screen the iPhone's backup waits.
    private static let backupPostponement: TimeInterval = 60
    /// The longest an open screen holds a request past its `expiresAt`. trio-rc's grace covers it, so don't change it.
    private static let openScreenHold: TimeInterval = 10 * 60
    /// Sent when the Treatments sheet asked for a bolus that neither started nor failed, as when Face ID was canceled.
    private static let bolusNotStartedReason = String(
        localized: "The bolus wasn't started",
        comment: "Report reason: the wearer asked for a bolus on the Treatments sheet, but it wasn't started"
    )
    /// Sent when the wearer has turned meal requests off.
    private static let mealRequestsOffReason = "Meal requests are off in Trio"
    /// Sent at launch for an approval Trio stopped carrying out before it started the bolus.
    private static let stoppedReason = "Trio stopped before it finished"
    /// Sent at launch for an approval Trio stopped carrying out while it started the bolus.
    private static let stoppedWhileEnactingReason = "Trio stopped while starting the bolus. It may have been given"

    private struct FinalReport: Codable {
        let id: String
        let reportedAt: Date
        let report: AIRequestReport
    }

    /// A request a device took out of pending to carry out.
    private struct Claim {
        let pending: PendingAIRequest
        let side: AIRequestAnswerSide
    }

    init(
        seen: AIRequestSeenStore,
        pendingFileURL: URL,
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
        self.preferences = preferences
        self.treatments = treatments
        self.watch = watch
        self.phoneBackup = phoneBackup
        self.reporters = reporters
        self.now = now
        current = CurrentValueSubject(nil)
        left = PassthroughSubject()
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
            await reportFinal(.expired, id: request.id, via: channel)
            return
        }
        if !preferences().allowsMealRequests {
            let refused = AIRequestReport.failed(reason: Self.mealRequestsOffReason, carbsLogged: false)
            await reportFinal(refused, id: request.id, via: channel)
            return
        }
        if let reason = limitFailure(for: request) {
            let refused = AIRequestReport.failed(reason: reason, carbsLogged: false)
            await reportFinal(refused, id: request.id, via: channel)
            return
        }

        let dose = await treatments.dose(forCarbs: request.carbs)
        let units = Self.shownUnits(dose.units)
        let context = await treatments.context(for: request, units: units)

        // Nothing suspends from here to the reports, so no other call sees the swap half done.
        let replaced = takePending(.replaced)
        let preferences = self.preferences()
        let askedOn: AIRequestAskedOn = watch.isWatchAvailable ? .watch : .phone
        let shown = AIRequestShown(carbs: request.carbs, fat: request.fat, protein: request.protein, units: units)
        let display = AIRequestDisplayText.display(
            source: request.source,
            description: request.description,
            shown: shown,
            context: context
        )
        let prompt = AIRequestPrompt(
            id: request.id,
            source: request.source,
            description: request.description,
            shown: shown,
            title: display.title,
            body: display.body,
            expiresAt: request.expiresAt,
            context: context
        )
        let phoneDelay = askedOn == .phone ? 0 : preferences.phoneBackupDelay
        let pending = PendingAIRequest(
            request: request,
            channel: channel,
            prompt: prompt,
            askedOn: askedOn,
            units: units,
            receivedAt: receivedAt,
            phoneAskAt: now().addingTimeInterval(phoneDelay)
        )
        current.send(pending)
        savePending(pending)
        scheduleExpiryCheck(at: request.expiresAt)
        phoneBackup.schedule(prompt, after: phoneDelay, askedOn: askedOn)
        debug(.service, "AI requests: \(request.id) is pending, asked on the \(askedOn.rawValue)")

        if let replaced {
            await reportFinal(.replaced, id: replaced.request.id, via: replaced.channel)
        }
        await reporters[channel]?.report(.pending(askedOn: askedOn, shown: shown, display: display), for: request.id)
    }

    /// Withdraws a request its assistant cancelled. `request` is set when the inbox lists a withdrawn
    /// request: one Trio never saw is marked seen, so it's never asked later.
    func withdraw(id: String, request: AIMealRequest?, via channel: AIRequestChannel) async {
        ensureLoaded()
        if let pending = takePending(.withdrawn, id: id) {
            await reportFinal(.withdrawn, id: pending.request.id, via: pending.channel)
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
            await reportFinal(.withdrawn, id: request.id, via: channel)
        case let .seen(outcome)?:
            await reportRepeat(of: outcome, for: id, via: channel)
        case nil:
            return
        }
    }

    /// Expires the pending request if its time is up. While a device has it open on its screen, it waits until the
    /// screen confirms or closes it, but no longer than `openScreenHold` past its `expiresAt`, so a screen that's
    /// never closed, as when its app was killed, still lets it end.
    func expireIfDue() async {
        ensureLoaded()
        guard let pending = current.value, now() >= pending.request.expiresAt else { return }
        let holdEnd = pending.request.expiresAt.addingTimeInterval(Self.openScreenHold)
        if !openOn.isEmpty, now() < holdEnd {
            scheduleExpiryCheck(at: holdEnd)
            return
        }
        _ = takePending(.expired)
        await reportFinal(.expired, id: pending.request.id, via: pending.channel)
    }

    /// The watch opened the approval screen of the pending request, so the iPhone's backup waits: it's asked a minute
    /// from now instead. It's done once for each request, so a wearer who keeps reopening the screen doesn't put the
    /// backup off for good. Only a request the watch was asked first has a backup to wait.
    func postponePhoneBackup(id: String) {
        ensureLoaded()
        guard var pending = current.value, pending.request.id == id, pending.askedOn == .watch,
              now() < pending.request.expiresAt, postponedBackupID != id
        else { return }
        postponedBackupID = id
        pending.phoneAskAt = now().addingTimeInterval(Self.backupPostponement)
        current.send(pending)
        savePending(pending)
        phoneBackup.cancel(id: id)
        phoneBackup.schedule(pending.prompt, after: Self.backupPostponement, askedOn: pending.askedOn)
        debug(.service, "AI requests: the watch opened \(id), so the iPhone waits \(Int(Self.backupPostponement)) s")
    }

    // MARK: Screens

    /// A device opened the pending request on its screen: the Treatments sheet on the iPhone, or the Confirm flow on
    /// the watch. While it's open, the request doesn't expire (see `expireIfDue()`). The watch opening it puts the
    /// iPhone's backup off, once. Returns the request's amounts with Trio's dose for them worked out now, or `nil`
    /// unless `id` is pending. A request whose time is up, with no screen holding it, is expired instead.
    func open(id: String, on side: AIRequestAnswerSide) async -> AIRequestWatchDetails? {
        ensureLoaded()
        await expireIfDue()
        guard let pending = current.value, pending.request.id == id else {
            debug(.service, "AI requests: the \(side.rawValue) opened \(id), but it isn't pending")
            return nil
        }
        openOn.insert(side)
        if side == .watch {
            postponePhoneBackup(id: id)
        }
        let request = pending.request
        let dose = await treatments.dose(forCarbs: request.carbs)
        // It may have left pending while the dose was worked out.
        guard current.value?.request.id == id else { return nil }
        debug(.service, "AI requests: the \(side.rawValue) opened \(id)")
        return AIRequestWatchDetails(
            id: id,
            carbs: request.carbs,
            fat: request.fat,
            protein: request.protein,
            units: Self.shownUnits(dose.units),
            expiresAt: request.expiresAt
        )
    }

    /// A device closed the request's screen without confirming it. If it's still pending, nobody claimed it, so it's
    /// declined on that device, or dismissed when the wearer swiped the watch's notification away, which only the
    /// watch has: `dismissed` is ignored for the iPhone. Otherwise there's nothing to do: the screens a request had
    /// open were let go when it left pending.
    func close(id: String, on side: AIRequestAnswerSide, dismissed: Bool) async {
        ensureLoaded()
        await expireIfDue()
        let declinedOn: AIRequestDeclinedOn = switch side {
        case .phone: .phone
        case .watch: dismissed ? .dismissed : .watch
        }
        guard let pending = takePending(.declined(declinedOn), id: id) else {
            debug(.service, "AI requests: the \(side.rawValue) closed \(id), which isn't pending")
            return
        }
        await reportFinal(.declined(on: declinedOn), id: pending.request.id, via: pending.channel)
    }

    /// The iPhone's Treatments sheet takes the request out of pending to carry it out, so the watch can't. Returns
    /// `false` unless `id` is pending, and always for the watch, which carries a request out with
    /// `carryOutWatchConfirm(_:)` and so never holds a claim. The iPhone reports what it did with
    /// `reportPhoneResult(id:_:)`.
    func claim(id: String, on side: AIRequestAnswerSide) async -> Bool {
        ensureLoaded()
        guard side == .phone else {
            debug(.service, "AI requests: refused the watch's claim on \(id), it confirms with carryOutWatchConfirm")
            return false
        }
        guard let pending = await takeClaimed(id: id, on: side) else { return false }
        claims[id] = Claim(pending: pending, side: side)
        return true
    }

    /// Carries out what the wearer confirmed on the watch: claims the request for the watch, stores its carbs (its own
    /// grams, or the watch's when the wearer changed them) with its fat and protein, then gives the units, at most the
    /// max bolus. Returns the final report, or `nil` when the claim failed, as when the iPhone claimed it first: then
    /// nothing is logged.
    func carryOutWatchConfirm(_ confirm: AIRequestWatchConfirm) async -> AIRequestReport? {
        ensureLoaded()
        guard let pending = await takeClaimed(id: confirm.id, on: .watch) else { return nil }
        let previous = carryingOut
        let task = Task {
            _ = await previous?.value
            return await self.carryOut(pending, confirmed: confirm)
        }
        carryingOut = task
        return await task.value
    }

    /// The final report of a request the iPhone claimed, from what its Treatments sheet logged and gave. Only the first
    /// result after the claim is reported.
    func reportPhoneResult(id: String, _ result: AIRequestPhoneResult) async {
        ensureLoaded()
        guard let claim = claims[id], claim.side == .phone else {
            debug(.service, "AI requests: ignored the iPhone's result for \(id), the iPhone hasn't claimed it")
            return
        }
        claims[id] = nil
        await reportFinal(Self.report(for: result), id: id, via: claim.pending.channel)
    }

    /// The report for what the Treatments sheet did. It says what was actually logged and given.
    static func report(for result: AIRequestPhoneResult) -> AIRequestReport {
        let carbsLogged = result.carbs > 0 || result.fat > 0 || result.protein > 0
        func shown(units: Decimal) -> AIRequestShown {
            AIRequestShown(carbs: result.carbs, fat: result.fat, protein: result.protein, units: units)
        }
        switch result.bolus {
        case .started:
            return .delivering(shown: shown(units: result.units))
        case .none:
            return .logged(shown: shown(units: 0))
        case .external:
            // The insulin was given outside Trio, and logged with the carbs.
            return .logged(shown: shown(units: result.units))
        case let .failed(reason):
            return .failed(reason: reason, carbsLogged: carbsLogged)
        case .notStarted:
            return .failed(reason: Self.bolusNotStartedReason, carbsLogged: carbsLogged)
        }
    }

    /// Takes the request out of pending for the device that claimed it, or returns `nil` unless `id` is pending.
    private func takeClaimed(id: String, on side: AIRequestAnswerSide) async -> PendingAIRequest? {
        // A request whose time is up, with no screen holding it, can't be claimed.
        await expireIfDue()
        guard let pending = takePending(.claimed(side), id: id) else {
            debug(.service, "AI requests: the \(side.rawValue) couldn't claim \(id), it isn't pending")
            return nil
        }
        debug(.service, "AI requests: the \(side.rawValue) claimed \(id)")
        return pending
    }

    /// Carries out the watch's confirmation. A marker on disk says how far it got until the final report. The carbs are
    /// stored, unless there are none to log, then the units are given when above 0. A failed bolus keeps the carbs,
    /// because the food was eaten. Each report says what was actually done. Returns the final report.
    private func carryOut(_ pending: PendingAIRequest, confirmed confirm: AIRequestWatchConfirm) async -> AIRequestReport {
        // Before this confirmation's marker replaces it on disk.
        await reportStoppedCarryOut()
        let request = pending.request
        let carbs = confirm.carbs ?? request.carbs
        let units = max(0, min(confirm.units, treatments.limits.maxBolus))
        mark(AIRequestCarryOutMarker(
            id: request.id,
            channel: pending.channel,
            title: pending.prompt.title,
            source: request.source,
            shown: pending.prompt.shown,
            askedOn: pending.askedOn,
            approvedOn: .watch,
            stage: .checking
        ))
        // The watch's own carbs, if the wearer changed them, weren't checked when the request arrived.
        if let failure = limitFailure(carbs: carbs, fat: request.fat, protein: request.protein) {
            return await reportFinal(.failed(reason: failure, carbsLogged: false), id: request.id, via: pending.channel)
        }

        let carbsLogged = carbs > 0 || request.fat > 0 || request.protein > 0
        if carbsLogged {
            mark(.storingCarbs)
            do {
                try await treatments.storeCarbs(for: request, carbs: confirm.carbs)
            } catch {
                return await reportFinal(
                    .failed(reason: error.localizedDescription, carbsLogged: false),
                    id: request.id,
                    via: pending.channel
                )
            }
        }

        let done = AIRequestShown(carbs: carbs, fat: request.fat, protein: request.protein, units: units)
        guard units > 0 else {
            return await reportFinal(.logged(shown: done), id: request.id, via: pending.channel)
        }
        mark(.enacting)
        if let reason = await treatments.enactBolus(units) {
            return await reportFinal(.failed(reason: reason, carbsLogged: carbsLogged), id: request.id, via: pending.channel)
        }
        return await reportFinal(.delivering(shown: done), id: request.id, via: pending.channel)
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
        await reportFinal(failed, id: stopped.id, via: stopped.channel)
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
        limitFailure(carbs: request.carbs, fat: request.fat, protein: request.protein)
    }

    private func limitFailure(carbs: Decimal, fat: Decimal, protein: Decimal) -> String? {
        if carbs < 0 || fat < 0 || protein < 0 { return "Invalid amounts" }
        let limits = treatments.limits
        if carbs > limits.maxCarbs { return "Over your max carbs (\(limits.maxCarbs) g)" }
        if fat > limits.maxFat { return "Over your max fat (\(limits.maxFat) g)" }
        if protein > limits.maxProtein { return "Over your max protein (\(limits.maxProtein) g)" }
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
            expiresAt: expiresAt
        )
    }

    /// Takes the pending request out of pending, so nothing else can replace, expire, withdraw, decline or claim it,
    /// and sends `left` with `reason`. Nothing in it awaits, so `left` goes out before the caller's first await.
    private func takePending(_ reason: AIRequestLeft) -> PendingAIRequest? {
        guard let pending = current.value else { return nil }
        expiryCheck?.cancel()
        expiryCheck = nil
        openOn = []
        current.send(nil)
        deletePendingFile()
        phoneBackup.cancel(id: pending.request.id)
        left.send((id: pending.request.id, left: reason, source: pending.request.source))
        return pending
    }

    /// Takes the pending request out of pending only if it has this ID, so another request is never declined,
    /// claimed or withdrawn in its place.
    private func takePending(_ reason: AIRequestLeft, id: String) -> PendingAIRequest? {
        guard current.value?.request.id == id else { return nil }
        return takePending(reason)
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

    /// Saves the request's first final report and reports it to where the request came from. Returns the report.
    @discardableResult private func reportFinal(
        _ report: AIRequestReport,
        id: String,
        via channel: AIRequestChannel
    ) async -> AIRequestReport {
        seen.setOutcome(report.state, for: id)
        saveFinalReport(report, for: id)
        // After the final report is saved, so a launch that finds the marker can tell it was reported.
        removeCarryOutMarker(for: id)
        debug(.service, "AI requests: \(id) is \(report.state.rawValue)")
        await reporters[channel]?.report(report, for: id)
        return report
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
            shown: pending.prompt.shown,
            display: AIRequestDisplay(
                title: pending.prompt.title,
                body: pending.prompt.body,
                context: pending.prompt.context
            )
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
