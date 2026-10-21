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
    /// Runs as the wearer starts another flow on top of the request's screens, before that flow's screens read the
    /// carbs and dose the request put in them: they're zeroed, so that flow starts from nothing, as upstream's own does.
    @ObservationIgnored var onAnotherFlowStarted: () -> Void = {}
    /// The watch's bolus increment, which upstream's Confirm screen floors its dose to.
    @ObservationIgnored var bolusIncrement: Decimal = 0.05
    /// The bolus on upstream's Confirm screen, the Double it floors to show its dose. Read as its bolus send is caught,
    /// before upstream zeroes it. Without it, the amount upstream passes is used.
    @ObservationIgnored var screenBolus: (() -> Double)?

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
    /// Set when another request is opened while a flow's screens are up: their sends (upstream's Confirm sends 0.1 s
    /// after the crown) are dropped until the new request's screens are up, or the path is empty once it's no longer
    /// opening.
    @ObservationIgnored private var holdsSends = false
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
        if screensUp {
            holdsSends = true
        }
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

    /// The bolus the flow loads into the watch's screens for Trio's dose: a millionth of a step above it, so that
    /// Confirm's floor in Double lands on the dose rather than a step below (2.15 / 0.05 is 42.999… in Double). The
    /// floor keeps it from ever showing or sending more than the dose.
    func loadedBolus(for units: Decimal) -> Double {
        let bolus = Double(truncating: units as NSNumber)
        guard bolus > 0 else { return 0 }
        return bolus + Double(truncating: bolusIncrement as NSNumber) * 1E-6
    }

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
        guard case let .active(details) = phase, !holdsSends else { return drops("carbs") }
        recordedCarbs = RecordedCarbs(grams: amount == requestedCarbs ? nil : Decimal(amount))
        onIntercepted()
        let flow = flow
        nextTurn { [weak self] in
            guard let self, self.flow == flow, self.phase == .active(details), let carbs = self.recordedCarbs else { return }
            self.confirm(details, units: 0, carbs: carbs.grams, carbsSent: true)
        }
        return true
    }

    /// Catches upstream's bolus send while a request is open, sends the confirmation with the carbs caught before it,
    /// and returns `true`. The dose sent is the one upstream's Confirm screen shows. Returns `false` without a request,
    /// for upstream to send it itself.
    func interceptBolus(_ amount: Decimal) -> Bool {
        guard case let .active(details) = phase, !holdsSends else { return drops("bolus") }
        let carbsSent = recordedCarbs != nil
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
        let bolus = screenBolus?() ?? Double(truncating: amount as NSNumber)
        confirm(details, units: shownDose(bolus), carbs: carbs, carbsSent: carbsSent)
        return true
    }

    /// Upstream's screens after each change: how many are on the navigation path, and the carbs and bolus they hold.
    /// The first report of screens while a request is active marks them up. Leaving them (the path emptied) declines
    /// the request, and is checked first, since Cancel empties the path and zeroes the values at once. More screens
    /// than the flow's own, before its confirm, are another flow the wearer started on top of them (see
    /// `anotherFlowStarted()`). Their values going to 0 under them (upstream zeroes them when the phone becomes
    /// reachable again) ends the flow without an answer. Once the screens of a flow that ended are gone, the watch is
    /// idle.
    func screensChanged(pathCount: Int, carbs: Int, bolus: Double) {
        if pathCount == 0 {
            let wereUp = screensUp
            screensUp = false
            switch phase {
            case .active,
                 .loading:
                // Another request is opening: the earlier screens' last send may still come.
                break
            default:
                holdsSends = false
            }
            if case .closing = phase {
                phase = .idle
            } else if wereUp {
                pathEmptied()
            }
            return
        }
        if case .active = phase, screensUp, pathCount > flowScreenCount, recordedCarbs == nil {
            anotherFlowStarted()
            return
        }
        if case .active = phase {
            screensUp = true
            holdsSends = false
        }
        if screensUp, carbs == 0, bolus == 0 {
            valuesZeroed()
        }
    }

    /// The wearer started another flow on top of the request's screens: they went up under the treatment menu, which
    /// covered the main screen, and the wearer picked a treatment from it. The request is declined, its carbs and dose
    /// are zeroed, and the watch is idle at once, holding nothing, so that flow's sends go to the phone as upstream's
    /// own. Backing out of that flow onto the request's screens shows nothing to send.
    private func anotherFlowStarted() {
        guard case let .active(details) = phase else { return }
        flow += 1
        screensUp = false
        holdsSends = false
        phase = .idle
        onAnotherFlowStarted()
        sendMessage(AIRequestWatchClose(id: details.id, dismissed: false), as: AIRequestIdentifiers.keyClose)
    }

    /// How many screens the flow opens: Confirm, with the bolus screen behind it, and the carbs screen behind that
    /// when there are carbs. The watch's `aiRequestFlow` modifier opens them so.
    private var flowScreenCount: Int {
        requestedCarbs > 0 ? 3 : 2
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

    /// Sends the confirmation. A confirm of 0 U with no carbs send, from a Confirm screen that had shown a dose or carbs,
    /// is values zeroed under it: neither logged nor declined. The flow ends, and the request keeps waiting.
    private func confirm(_ details: AIRequestWatchDetails, units: Decimal, carbs: Decimal?, carbsSent: Bool) {
        recordedCarbs = nil
        if units <= 0, !carbsSent, hasAmounts(details) {
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
    /// confirmed, are still up, and while another request is opening over them. Otherwise it's upstream's own, and goes
    /// to the phone as it always does.
    private func drops(_ kind: String) -> Bool {
        guard screensUp || holdsSends else { return false }
        log("dropped a \(kind) send from the screens of a request whose flow has ended")
        return true
    }

    /// The dose upstream's Confirm screen shows for its `bolus`: `floor(bolus / increment) * increment`, the expression
    /// it uses, in Double, then as a Decimal rounded to the increment's decimals, so no binary tail goes with it.
    private func shownDose(_ bolus: Double) -> Decimal {
        let increment = Double(truncating: bolusIncrement as NSNumber)
        let shown = increment > 0 ? floor(bolus / increment) * increment : bolus
        guard shown.isFinite, shown > 0 else { return 0 }
        var dose = Decimal(shown)
        var clean = Decimal()
        NSDecimalRound(&clean, &dose, Self.decimals(of: increment), .plain)
        return clean
    }

    /// How many decimals the bolus increment has: 2 for 0.05, 1 for 0.1. It may come as a Double, with a tail.
    private static func decimals(of increment: Double) -> Int {
        for places in 0 ..< 6 {
            let scaled = increment * pow(10, Double(places))
            if abs(scaled - scaled.rounded()) < 1E-9 {
                return places
            }
        }
        return 6
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
