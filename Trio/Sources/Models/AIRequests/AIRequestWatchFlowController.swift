import Foundation
import Observation

/// An AI assistant's request on the watch's own bolus screens. Review asks the phone for the request; its details open
/// upstream's Confirm screen, with the bolus and carbs screens behind it. While a request is open, upstream's two send
/// calls from those screens are caught and become one confirmation; leaving the screens declines the request. While
/// the screens of a flow that ended are still up, their sends are dropped, so none reaches the phone as a plain carbs or
/// bolus request. The watch's `aiRequestFlow` modifier drives the screens from `phase` and `notice`, and reports them
/// back with `screensChanged`. With no request open, nothing is caught, and upstream's screens work as they always do.
///
/// Main queue only, except `notificationDismissed(id:)`, which only sends.
@Observable final class AIRequestWatchFlowController {
    enum Phase: Equatable {
        case idle
        /// Waiting for the phone's details of the request.
        case loading(id: String)
        /// The phone didn't send the details in time.
        case unreachable(id: String)
        /// Upstream's screens show the request.
        case active(AIRequestWatchDetails)
        /// The wearer confirmed. The phone's acknowledgement, on upstream's acknowledgement screen, says how it went.
        case confirmed(id: String)
        /// The flow ended without the watch's confirm while its screens were up. Until they're gone, upstream's sends
        /// from them are dropped: its Confirm still sends 0.1 s after the crown, even once the screen has gone.
        case closing(id: String)
    }

    /// What the watch shows when a flow ends without the phone's acknowledgement.
    struct Notice: Equatable {
        let message: String
        let isSuccess: Bool
        /// Counts the notices, so the same text twice is still two notices.
        let serial: Int
    }

    /// The carbs a send call gave, until they're sent: `nil` for the request's exact grams.
    private struct RecordedCarbs {
        let grams: Decimal?
    }

    static let shared = AIRequestWatchFlowController()

    /// How long the watch waits for the phone's details.
    static let detailsWait: TimeInterval = 5

    private(set) var phase: Phase = .idle
    private(set) var notice: Notice?
    /// The request's carbs in the whole grams the watch's screens hold.
    private(set) var requestedCarbs = 0

    /// Runs as a send call is caught for a confirmation, before upstream's screen moves on to its acknowledgement
    /// screen.
    @ObservationIgnored var onIntercepted: () -> Void = {}
    /// The watch's bolus increment, which upstream's Confirm screen floors its dose to.
    @ObservationIgnored var bolusIncrement: Decimal = 0.05

    @ObservationIgnored private var send: ([String: Any]) -> Void
    @ObservationIgnored private var log: (String) -> Void
    @ObservationIgnored private let nextTurn: (@escaping () -> Void) -> Void
    @ObservationIgnored private let wait: (TimeInterval, @escaping () -> Void) -> Void
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let gramFormatter: NumberFormatter
    @ObservationIgnored private var recordedCarbs: RecordedCarbs?
    /// Whether a flow's screens are up: from the first report of them while its request is active, until a report that
    /// they're gone.
    @ObservationIgnored private var screensUp = false
    /// Counts the flows, so a wait or a turn left by an earlier one does nothing.
    @ObservationIgnored private var flow = 0
    @ObservationIgnored private var notices = 0

    /// - Parameters:
    ///   - send: Sends a message to the phone.
    ///   - nextTurn: Runs the work on the next turn of the main queue.
    ///   - wait: Runs the work on the main queue once the seconds have passed.
    ///   - log: Writes a line to the watch's log.
    init(
        send: @escaping ([String: Any]) -> Void = { _ in },
        nextTurn: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        wait: @escaping (TimeInterval, @escaping () -> Void) -> Void = AIRequestWatchFlowController.waitOnMain,
        locale: Locale = .current,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.send = send
        self.nextTurn = nextTurn
        self.wait = wait
        self.locale = locale
        self.log = log
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        gramFormatter = formatter
    }

    /// Sends the flow's messages to the phone, and writes its log lines, from now on.
    func connect(send: @escaping ([String: Any]) -> Void, log: @escaping (String) -> Void) {
        self.send = send
        self.log = log
    }

    // MARK: Opening

    /// The wearer opened the request: the phone is asked for its details, and has 5 s to send them. The phone sends
    /// none for a request that isn't pending any more.
    func open(id: String) {
        flow += 1
        let flow = flow
        recordedCarbs = nil
        phase = .loading(id: id)
        send([AIRequestIdentifiers.keyOpen: id])
        wait(Self.detailsWait) { [weak self] in
            guard let self, self.flow == flow, self.phase == .loading(id: id) else { return }
            self.end(id, notice: Self.openOnIPhoneText, isSuccess: false, unshown: .unreachable(id: id))
        }
    }

    /// The phone's details of the request the watch is waiting for open its screens. Their expiry isn't checked: the
    /// phone holds the request while its screens are open.
    func receive(_ details: AIRequestWatchDetails) {
        guard phase == .loading(id: details.id) else { return }
        requestedCarbs = Int((details.carbs as NSDecimalNumber).doubleValue.rounded())
        phase = .active(details)
    }

    // MARK: Upstream's screens

    /// The Confirm screen's carbs, as the request's exact grams while the watch's whole grams are the request's own;
    /// `nil` otherwise, for upstream's own text.
    func carbsText(forAmount amount: Int) -> String? {
        guard case let .active(details) = phase, amount == requestedCarbs else { return nil }
        let grams = gramFormatter.string(from: details.carbs as NSDecimalNumber) ?? "\(details.carbs)"
        return String(
            localized: "\(grams) g",
            locale: locale,
            comment: "Carbs of an AI assistant's request on the watch's Confirm screen, in grams that may have decimals"
        )
    }

    /// Catches upstream's carbs send while a request is open, and returns `true`. The carbs go with the bolus send that
    /// upstream's Confirm makes right after; without one (Log Carbs), they go on their own on the next main-queue turn.
    /// Returns `false` without a request, for upstream to send them itself.
    func interceptCarbs(_ amount: Int) -> Bool {
        guard case let .active(details) = phase else { return drops("carbs") }
        recordedCarbs = RecordedCarbs(grams: amount == requestedCarbs ? nil : Decimal(amount))
        onIntercepted()
        let flow = flow
        nextTurn { [weak self] in
            guard let self, self.flow == flow, self.phase == .active(details), let carbs = self.recordedCarbs else { return }
            self.confirm(details, units: 0, carbs: carbs.grams)
        }
        return true
    }

    /// Catches upstream's bolus send while a request is open, sends the confirmation with the carbs caught before it,
    /// and returns `true`. The dose sent is the one upstream's Confirm screen shows. Returns `false` without a request,
    /// for upstream to send it itself.
    func interceptBolus(_ amount: Decimal) -> Bool {
        guard case let .active(details) = phase else { return drops("bolus") }
        let carbs: Decimal?
        if let recorded = recordedCarbs {
            carbs = recorded.grams
        } else if requestedCarbs == 0 {
            // No carbs row (a request under half a gram, or none): the request's own grams.
            carbs = nil
        } else {
            // Upstream's Confirm sends carbs only when there are some: the wearer has 0 g.
            carbs = 0
        }
        onIntercepted()
        confirm(details, units: shownDose(amount), carbs: carbs)
        return true
    }

    /// Upstream's screens after each change: whether the navigation path is empty, and the carbs and bolus they hold.
    /// The first report of screens while a request is active marks them up. Leaving them (the path emptied) declines
    /// the request, and is checked first, since Cancel empties the path and zeroes the values at once. Their values
    /// going to 0 under them (upstream zeroes them when the phone becomes reachable again) ends the flow without an
    /// answer. Once the screens of a flow that ended are gone, the watch is idle.
    func screensChanged(pathIsEmpty: Bool, carbs: Int, bolus: Double) {
        if pathIsEmpty {
            let wereUp = screensUp
            screensUp = false
            if case .closing = phase {
                phase = .idle
            } else if wereUp {
                pathEmptied()
            }
            return
        }
        if case .active = phase {
            screensUp = true
        }
        if screensUp, carbs == 0, bolus == 0 {
            valuesZeroed()
        }
    }

    /// The wearer left the request's screens without confirming: it's declined.
    func pathEmptied() {
        guard case let .active(details) = phase, recordedCarbs == nil else { return }
        flow += 1
        screensUp = false
        phase = .idle
        sendMessage(AIRequestWatchClose(id: details.id, dismissed: false), as: AIRequestIdentifiers.keyClose)
    }

    /// Upstream zeroed the screens' carbs and bolus. The flow ends without an answer, and the request keeps waiting.
    func valuesZeroed() {
        guard case let .active(details) = phase, recordedCarbs == nil, hasAmounts(details) else { return }
        end(details.id, notice: Self.openAgainText, isSuccess: false)
    }

    // MARK: The phone

    /// The request left pending on the phone. Its open flow ends with the phone's headline. Once the watch confirmed it,
    /// the phone's acknowledgement is the one result shown, so this is ignored.
    func ended(_ ended: AIRequestEnded) {
        switch phase {
        case let .active(details) where details.id == ended.id:
            break
        case let .loading(id) where id == ended.id:
            break
        default:
            return
        }
        end(ended.id, notice: ended.headline, isSuccess: ended.isSuccess)
    }

    /// The confirmation didn't reach the phone, so nothing was logged or given.
    func confirmNotDelivered(id: String) {
        guard phase == .confirmed(id: id) else { return }
        end(id, notice: Self.openOnIPhoneText, isSuccess: false)
    }

    /// The wearer swiped the request's notification away: it's declined.
    func notificationDismissed(id: String) {
        sendMessage(AIRequestWatchClose(id: id, dismissed: true), as: AIRequestIdentifiers.keyClose)
    }

    // MARK: Helpers

    /// Sends the confirmation. Values zeroed under the Confirm screen (both 0 for a request that had carbs or a dose)
    /// are neither logged nor declined: the flow ends, and the request keeps waiting.
    private func confirm(_ details: AIRequestWatchDetails, units: Decimal, carbs: Decimal?) {
        recordedCarbs = nil
        if units <= 0, (carbs ?? details.carbs) <= 0, hasAmounts(details) {
            end(details.id, notice: Self.openAgainText, isSuccess: false)
            return
        }
        phase = .confirmed(id: details.id)
        let confirm = AIRequestWatchConfirm(id: details.id, units: units, carbs: carbs)
        if !sendMessage(confirm, as: AIRequestIdentifiers.keyConfirm) {
            confirmNotDelivered(id: details.id)
        }
    }

    /// Whether a send from upstream's screens is dropped: it is while the screens of a flow that ended, or was
    /// confirmed, are still up. Otherwise it's upstream's own, and goes to the phone as it always does.
    private func drops(_ kind: String) -> Bool {
        guard screensUp else { return false }
        log("dropped a \(kind) send from the screens of a request whose flow has ended")
        return true
    }

    /// The dose upstream's Confirm screen shows for `amount`: floored to the bolus increment as the screen floors it,
    /// in Double, then made a whole number of increments, rounded to the two places the screen shows, so no binary
    /// tail goes with it.
    private func shownDose(_ amount: Decimal) -> Decimal {
        let increment = Double(truncating: bolusIncrement as NSNumber)
        guard increment > 0 else { return amount }
        let steps = (Double(truncating: amount as NSNumber) / increment).rounded(.down)
        guard steps.isFinite, steps > 0 else { return 0 }
        var dose = Decimal(steps) * bolusIncrement
        var shown = Decimal()
        NSDecimalRound(&shown, &dose, 2, .plain)
        return shown
    }

    /// Whether the screens opened with carbs or a dose, so both being 0 means they were zeroed.
    private func hasAmounts(_ details: AIRequestWatchDetails) -> Bool {
        requestedCarbs > 0 || details.units > 0
    }

    /// Ends the flow with a notice. While its screens are still up it's closing, so their sends are dropped until
    /// they're gone; otherwise it's `unshown`.
    private func end(_ id: String, notice message: String, isSuccess: Bool, unshown: Phase = .idle) {
        flow += 1
        recordedCarbs = nil
        phase = screensUp ? .closing(id: id) : unshown
        notices += 1
        notice = Notice(message: message, isSuccess: isSuccess, serial: notices)
    }

    /// Encodes and sends a message. Returns `false`, and logs it, when it couldn't be encoded.
    @discardableResult private func sendMessage(_ message: some Encodable, as key: String) -> Bool {
        do {
            send([key: try JSONEncoder().encode(message)])
            return true
        } catch {
            log("couldn't encode a \(key) message, so it isn't sent: \(error)")
            return false
        }
    }

    private static var openOnIPhoneText: String {
        String(
            localized: "Open this request on your iPhone.",
            comment: "Watch notice when the iPhone couldn't be reached to open or confirm an AI assistant's request"
        )
    }

    private static var openAgainText: String {
        String(
            localized: "Open the request again.",
            comment: "Watch notice when an AI assistant's request closed because the watch's amounts were reset"
        )
    }

    /// Runs the work on the main queue once the seconds have passed. It isn't animation: it's the wait for the phone.
    static func waitOnMain(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            DispatchQueue.main.async {
                work()
            }
        }
    }
}
