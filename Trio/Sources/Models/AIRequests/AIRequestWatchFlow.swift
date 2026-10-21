import Foundation

/// What `AIRequestWatchCenter` did with an answer, for the approval screen to show.
enum AIRequestSendResult: Equatable {
    /// The answer went out: to the service, or live to the phone because it was reachable. Whether it got there isn't
    /// known until the phone's receipt.
    case sent
    /// The phone wasn't reachable and the service isn't used, so the answer waits in WatchConnectivity's queue for the
    /// phone. Nothing says when it will get there.
    case queued
    /// The answer wasn't sent at all: the watch has no key to sign it with yet, or the request had expired or been
    /// withdrawn.
    case notSent
}

/// Where the watch approval screen is. The phone's receipt and result move it on; the watch's own clock only ever
/// expires a request nobody has answered.
enum AIRequestWatchPhase: Equatable {
    /// The request is shown, and the wearer hasn't answered.
    case asking
    /// The wearer answered at `since`. `queued` means the phone wasn't reachable.
    case sending(AIRequestDecision, since: Date, queued: Bool)
    /// The phone withdrew the request after the wearer answered. It has the answer, or the request ended another way
    /// (it expired, was replaced or was canceled), so only its result says which.
    case received(AIRequestDecision)
    /// The answer couldn't be sent, so the wearer answers on the iPhone.
    case notSent
    /// The phone's word on how the request ended.
    case result(AIRequestResultMessage)
    /// Nobody answered before the request expired.
    case expired
}

/// How the approval screen leaves a phase.
enum AIRequestWatchEnding: Equatable {
    /// Nothing to press: the phone's receipt or result moves it on. The asking screen has its own buttons.
    case waits
    /// Closes by itself when its ring runs out, or with Done.
    case closesBySelf(AIRequestWatchRing)
    /// Stays until the wearer presses Close.
    case close
}

/// The closing ring's look.
enum AIRequestWatchRing: Equatable {
    /// The request was carried out: the bolus started, the carbs were logged, or a test passed.
    case success
    /// Nothing happened, as the wearer asked.
    case neutral

    /// How long the ring takes to run out, and so how long the screen stays before it closes. A success is held a little
    /// longer than a decline, which the wearer already knows.
    var drainDuration: TimeInterval {
        switch self {
        case .success:
            return 1.5
        case .neutral:
            return 1.0
        }
    }
}

/// The haptic the watch plays as the approval screen moves from one phase to another.
enum AIRequestWatchHaptic: Equatable {
    /// The wearer committed to an approval, or the request was carried out.
    case success
    /// The answer wasn't sent, the request failed or ran out, or the dose wasn't given.
    case failure
    /// The wearer declined.
    case directionDown
}

/// The watch approval screen's phases, and its words for each. A plain value with no clock of its own: the view
/// passes the time in, so every rule here is testable.
struct AIRequestWatchFlow: Equatable {
    /// How long after the screen opens an Approve is ignored, so a tap or a double tap that was already under way
    /// when the request arrived can't dose.
    static let armingDelay: TimeInterval = 1
    /// How long an answer can wait for the phone's receipt before the screen says there's been no reply.
    static let noReplyAfter: TimeInterval = 15
    /// With less than this left to answer, the screen counts down.
    static let countdownFrom: TimeInterval = 60

    let shownAt: Date
    let expiresAt: Date
    private(set) var phase: AIRequestWatchPhase = .asking
    /// The wearer's answer on this screen, sent or not. It decides whether a neutral result can close by itself.
    private(set) var decision: AIRequestDecision?

    init(shownAt: Date, expiresAt: Date) {
        self.shownAt = shownAt
        self.expiresAt = expiresAt
    }

    /// The wearer answered, and `result` is what became of sending it. Only a request still being asked takes an
    /// answer; the first one stands. The caller checks `acceptsApprove(at:)` before it sends an Approve.
    mutating func answered(_ decision: AIRequestDecision, _ result: AIRequestSendResult, at now: Date) {
        guard phase == .asking else { return }
        self.decision = decision
        switch result {
        case .sent:
            phase = .sending(decision, since: now, queued: false)
        case .queued:
            phase = .sending(decision, since: now, queued: true)
        case .notSent:
            phase = .notSent
        }
    }

    /// The phone has the answer. Only a sent answer moves: a receipt for anything else, or a second receipt, is
    /// ignored.
    mutating func receiptArrived() {
        guard case let .sending(decision, _, _) = phase else { return }
        phase = .received(decision)
    }

    /// The phone's word on how the request ended. It replaces any phase, with one exception: a request that expired
    /// before anyone answered keeps `.expired` when the phone also says nobody answered, because the screen already
    /// says so. A result that says someone did answer still replaces `.expired`: the wearer answered on the iPhone just
    /// before the request ran out, and "Nothing was logged" would be wrong.
    mutating func resultArrived(_ message: AIRequestResultMessage) {
        if phase == .expired, message.answeredOn == nil { return }
        phase = .result(message)
    }

    /// Expires a request nobody has answered once its time is up. An answered request keeps its phase.
    mutating func expireIfDue(at now: Date) {
        guard phase == .asking, now >= expiresAt else { return }
        phase = .expired
    }

    /// Whether the screen takes an Approve now: it is still asking, and it has been open for the arming delay.
    func acceptsApprove(at now: Date) -> Bool {
        phase == .asking && now.timeIntervalSince(shownAt) >= Self.armingDelay
    }

    /// Whether the answer has waited too long for the phone's receipt. It's a way of showing `.sending`, not a phase
    /// of its own: a receipt that arrives late still moves the screen on.
    func isNoReply(at now: Date) -> Bool {
        guard case let .sending(_, since, _) = phase else { return false }
        return now >= since.addingTimeInterval(Self.noReplyAfter)
    }

    /// How the screen leaves the phase now. Only an outcome the wearer can take as read closes by itself: a success,
    /// or nothing happening after a decline. Anything else after an Approve, a warning or failure, no reply, a request
    /// that wasn't sent and an expiry wait for Close, so the screen never shows a success it doesn't know about. A
    /// neutral result for a request not answered here waits too: the screen can't tell whether the wearer declined it.
    func ending(at now: Date) -> AIRequestWatchEnding {
        switch phase {
        case .asking:
            return .waits
        case .sending:
            return isNoReply(at: now) ? .close : .waits
        case .received(.approve):
            // "Sent to Trio" isn't a result: the wearer can close it, and a failure still reaches them as a notification.
            return .close
        case .received(.decline):
            return .closesBySelf(.neutral)
        case .expired,
             .notSent:
            return .close
        case let .result(message):
            switch message.tone {
            case .success:
                return .closesBySelf(.success)
            case .neutral:
                return decision == .decline ? .closesBySelf(.neutral) : .close
            case .failure,
                 .warning:
                return .close
            }
        }
    }

    /// The haptic for the screen moving from phase `old` to phase `new`, or `nil` for none. It plays after the move, so it
    /// follows what became of sending the answer and never runs ahead of it: committing to an approve is felt only once
    /// the answer was sent or queued, and an answer that couldn't be sent is a failure, never a success.
    ///
    /// - Committing to an approve, by the crown, Approve or a double tap alike: success, once.
    /// - Declining: direction down.
    /// - An answer that wasn't sent, a request that expired on the screen, and a failure or warning from the phone (the
    ///   bolus the wearer approved wasn't given, or was only partly): failure.
    /// - A success from the phone: success.
    /// - Everything else, including the phone's receipt, a queued answer waiting and a neutral result: none.
    static func haptic(from old: AIRequestWatchPhase, to new: AIRequestWatchPhase) -> AIRequestWatchHaptic? {
        guard old != new else { return nil }
        switch new {
        case .asking,
             .received:
            return nil
        case let .sending(decision, _, _):
            // Only the answer itself: nothing else moves into sending.
            guard old == .asking else { return nil }
            return decision == .approve ? .success : .directionDown
        case .expired,
             .notSent:
            return .failure
        case let .result(message):
            switch message.tone {
            case .success:
                return .success
            case .failure,
                 .warning:
                return .failure
            case .neutral:
                return nil
            }
        }
    }

    /// The time left to answer as "m:ss", rounded up to whole seconds, once that's under `countdownFrom`: from "0:59"
    /// down to "0:00". `nil` before then, and once the request isn't being asked any more.
    func countdown(at now: Date) -> String? {
        guard phase == .asking else { return nil }
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        guard TimeInterval(seconds) < Self.countdownFrom else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The headline and detail for the phase. `units` is `AIRequestShown.units`, and `source` is the assistant's name.
    /// The asking phase has no words here: the view lays out the request itself.
    func text(at now: Date, units: String, source: String) -> (headline: String, detail: String?) {
        switch phase {
        case .asking:
            return ("", nil)
        case let .sending(decision, _, queued):
            if isNoReply(at: now) {
                return (
                    String(localized: "No reply from your iPhone yet", comment: "Watch approval: the iPhone hasn't confirmed"),
                    String(
                        localized: "Check Trio before you bolus yourself.",
                        comment: "Watch approval: no reply from the iPhone"
                    )
                )
            }
            if queued {
                return (String(localized: "Waiting for iPhone", comment: "Watch approval: the answer is queued"), nil)
            }
            switch decision {
            case .approve:
                return (
                    String(localized: "Approving \(units)\u{00A0}U…", comment: "Watch approval: sending the approval"),
                    nil
                )
            case .decline:
                return (String(localized: "Declining…", comment: "Watch approval: sending the decline"), nil)
            }
        case let .received(decision):
            switch decision {
            case .approve:
                // Not "Approved": the phone also withdraws a request that expired, was replaced or was canceled, so
                // only the result says the approval was taken.
                return (
                    String(
                        localized: "Sent to Trio",
                        comment: "Watch approval: the iPhone withdrew the request after the approval"
                    ),
                    String(
                        localized: "Waiting for the result.",
                        comment: "Watch approval: after an approval, until the iPhone's result"
                    )
                )
            case .decline:
                return (
                    String(localized: "Declined", comment: "Watch approval: the iPhone has the decline"),
                    String(localized: "Nothing was logged.", comment: "Watch approval: after a decline")
                )
            }
        case .notSent:
            return (
                String(localized: "Couldn't send", comment: "Watch approval: the answer wasn't sent"),
                String(localized: "Answer on your iPhone.", comment: "Watch approval: the answer wasn't sent")
            )
        case .expired:
            return (
                String(localized: "Expired", comment: "Watch approval: the request ran out"),
                String(
                    localized: "Nothing was logged. Ask \(source) again if you still want it.",
                    comment: "Watch approval: the request ran out"
                )
            )
        case let .result(message):
            return (message.headline, message.detail)
        }
    }
}
