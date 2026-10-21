import Foundation
import Testing

@testable import Trio

@Suite("AI request watch flow") struct AIRequestWatchFlowTests {
    private static let shownAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let expiresAt = shownAt.addingTimeInterval(300)

    private static func flow() -> AIRequestWatchFlow {
        AIRequestWatchFlow(shownAt: shownAt, expiresAt: expiresAt)
    }

    /// A flow whose answer was sent (or queued) one second after the screen opened.
    private static func sending(_ decision: AIRequestDecision = .approve, queued: Bool = false) -> AIRequestWatchFlow {
        var flow = flow()
        flow.answered(decision, queued ? .queued : .sent, at: shownAt.addingTimeInterval(1))
        return flow
    }

    private static func message(
        headline: String = "Bolus started: 2.10\u{00A0}U",
        detail: String = "35\u{00A0}g carbs logged.",
        tone: AIRequestResultMessage.Tone = .success,
        answeredOn: AIRequestAnswerSide? = .watch
    ) -> AIRequestResultMessage {
        AIRequestResultMessage(
            id: "r1",
            title: "ChatGPT: slice of pizza",
            headline: headline,
            detail: detail,
            tone: tone,
            answeredOn: answeredOn
        )
    }

    @Test(
        "Approve is ignored in the first second, so a stray tap or a double tap on arrival can't dose"
    ) func approveIgnoredInTheFirstSecond() {
        let flow = Self.flow()
        #expect(!flow.acceptsApprove(at: Self.shownAt))
        #expect(!flow.acceptsApprove(at: Self.shownAt.addingTimeInterval(0.5)))
        #expect(!flow.acceptsApprove(at: Self.shownAt.addingTimeInterval(0.99)))
        #expect(flow.acceptsApprove(at: Self.shownAt.addingTimeInterval(1)))
        #expect(flow.acceptsApprove(at: Self.shownAt.addingTimeInterval(30)))

        // Only the asking screen takes an Approve.
        let answered = Self.sending()
        #expect(!answered.acceptsApprove(at: Self.shownAt.addingTimeInterval(30)))
    }

    @Test("An answer moves to sending, or to not sent when there was no key to sign with") func answerMovesToSending() {
        let answeredAt = Self.shownAt.addingTimeInterval(4)

        var sent = Self.flow()
        sent.answered(.approve, .sent, at: answeredAt)
        #expect(sent.phase == .sending(.approve, since: answeredAt, queued: false))

        var queued = Self.flow()
        queued.answered(.approve, .queued, at: answeredAt)
        #expect(queued.phase == .sending(.approve, since: answeredAt, queued: true))

        var declined = Self.flow()
        declined.answered(.decline, .sent, at: answeredAt)
        #expect(declined.phase == .sending(.decline, since: answeredAt, queued: false))

        var notSent = Self.flow()
        notSent.answered(.approve, .notSent, at: answeredAt)
        #expect(notSent.phase == .notSent)

        // The first answer stands: a second one doesn't replace it.
        sent.answered(.decline, .queued, at: answeredAt.addingTimeInterval(2))
        #expect(sent.phase == .sending(.approve, since: answeredAt, queued: false))
    }

    @Test("The phone's receipt moves sending to received, and nothing else") func receiptMovesSendingToReceived() {
        var approved = Self.sending(.approve)
        approved.receiptArrived()
        #expect(approved.phase == .received(.approve))

        var declined = Self.sending(.decline)
        declined.receiptArrived()
        #expect(declined.phase == .received(.decline))

        // A queued answer is received just the same, once the phone gets it.
        var queued = Self.sending(.approve, queued: true)
        queued.receiptArrived()
        #expect(queued.phase == .received(.approve))

        // A receipt for a request still being asked, or not sent, or already resulted, changes nothing.
        var asking = Self.flow()
        asking.receiptArrived()
        #expect(asking.phase == .asking)

        var notSent = Self.flow()
        notSent.answered(.approve, .notSent, at: Self.shownAt.addingTimeInterval(2))
        notSent.receiptArrived()
        #expect(notSent.phase == .notSent)

        var resulted = Self.sending()
        resulted.resultArrived(Self.message())
        resulted.receiptArrived()
        #expect(resulted.phase == .result(Self.message()))

        var again = Self.sending(.decline)
        again.receiptArrived()
        again.receiptArrived()
        #expect(again.phase == .received(.decline))
    }

    @Test(
        "The phone's result replaces every answered phase, and a later result replaces an earlier one"
    ) func resultReplacesAnyAnsweredPhase() {
        let result = Self.message()

        var sending = Self.sending()
        sending.resultArrived(result)
        #expect(sending.phase == .result(result))

        var queued = Self.sending(queued: true)
        queued.resultArrived(result)
        #expect(queued.phase == .result(result))

        var received = Self.sending()
        received.receiptArrived()
        received.resultArrived(result)
        #expect(received.phase == .result(result))

        var notSent = Self.flow()
        notSent.answered(.approve, .notSent, at: Self.shownAt.addingTimeInterval(2))
        notSent.resultArrived(result)
        #expect(notSent.phase == .result(result))

        let later = Self.message(
            headline: "Bolus not confirmed",
            detail: "Check your pump.",
            tone: .warning
        )
        var replaced = Self.sending()
        replaced.resultArrived(result)
        replaced.resultArrived(later)
        #expect(replaced.phase == .result(later))
    }

    @Test(
        "A queued answer with no receipt becomes No reply after 15 s, never a tick"
    ) func queuedAnswerWithoutReceiptBecomesNoReply() {
        let answeredAt = Self.shownAt.addingTimeInterval(3)
        var flow = Self.flow()
        flow.answered(.approve, .queued, at: answeredAt)

        let before = answeredAt.addingTimeInterval(14.9)
        #expect(!flow.isNoReply(at: before))
        #expect(flow.text(at: before, units: "2.10", source: "ChatGPT").headline == "Waiting for iPhone")

        let after = answeredAt.addingTimeInterval(15)
        #expect(flow.isNoReply(at: after))
        let text = flow.text(at: after, units: "2.10", source: "ChatGPT")
        #expect(text.headline == "No reply from your iPhone yet")
        #expect(text.detail == "Check Trio before you bolus yourself.")
        // It's a way of showing the sending phase, not a phase of its own.
        #expect(flow.phase == .sending(.approve, since: answeredAt, queued: true))

        // The same goes for an answer that went out but never got a receipt.
        let sent = Self.sending()
        #expect(!sent.isNoReply(at: Self.shownAt.addingTimeInterval(1 + 14.9)))
        #expect(sent.isNoReply(at: Self.shownAt.addingTimeInterval(1 + 15)))

        // A receipt ends it, even when it arrives after the 15 s.
        var late = flow
        late.receiptArrived()
        #expect(!late.isNoReply(at: after.addingTimeInterval(60)))
        #expect(late.text(at: after.addingTimeInterval(60), units: "2.10", source: "ChatGPT").headline == "Sent to Trio")

        // Nothing is no-reply before an answer.
        #expect(!Self.flow().isNoReply(at: Self.shownAt.addingTimeInterval(600)))
    }

    @Test("Not sent stays until the phone's result arrives") func notSentIsTerminalUntilAResult() {
        var flow = Self.flow()
        flow.answered(.approve, .notSent, at: Self.shownAt.addingTimeInterval(2))
        #expect(flow.phase == .notSent)

        flow.receiptArrived()
        #expect(flow.phase == .notSent)

        flow.answered(.approve, .sent, at: Self.shownAt.addingTimeInterval(3))
        #expect(flow.phase == .notSent)

        flow.expireIfDue(at: Self.expiresAt.addingTimeInterval(60))
        #expect(flow.phase == .notSent)

        #expect(!flow.isNoReply(at: Self.shownAt.addingTimeInterval(600)))
        #expect(!flow.acceptsApprove(at: Self.shownAt.addingTimeInterval(30)))

        let result = Self.message(
            headline: "Declined",
            detail: "Nothing was logged.",
            tone: .neutral,
            answeredOn: .phone
        )
        flow.resultArrived(result)
        #expect(flow.phase == .result(result))
    }

    @Test("Only a request still being asked can expire") func expiryOnlyFromAsking() {
        var asking = Self.flow()
        asking.expireIfDue(at: Self.expiresAt.addingTimeInterval(-0.1))
        #expect(asking.phase == .asking)
        asking.expireIfDue(at: Self.expiresAt)
        #expect(asking.phase == .expired)

        // An expired request takes no answer, no receipt and no Approve.
        asking.answered(.approve, .sent, at: Self.expiresAt.addingTimeInterval(1))
        #expect(asking.phase == .expired)
        asking.receiptArrived()
        #expect(asking.phase == .expired)
        #expect(!asking.acceptsApprove(at: Self.expiresAt.addingTimeInterval(1)))

        // Past the expiry, an answer already sent, received, resulted or not sent stays as it is.
        let late = Self.expiresAt.addingTimeInterval(60)

        var sending = Self.sending()
        sending.expireIfDue(at: late)
        #expect(sending.phase == .sending(.approve, since: Self.shownAt.addingTimeInterval(1), queued: false))

        var received = Self.sending(.decline)
        received.receiptArrived()
        received.expireIfDue(at: late)
        #expect(received.phase == .received(.decline))

        var resulted = Self.sending()
        resulted.resultArrived(Self.message())
        resulted.expireIfDue(at: late)
        #expect(resulted.phase == .result(Self.message()))

        var notSent = Self.flow()
        notSent.answered(.approve, .notSent, at: Self.shownAt.addingTimeInterval(2))
        notSent.expireIfDue(at: late)
        #expect(notSent.phase == .notSent)
    }

    @Test(
        "A request that expired on the watch still shows what the phone did if someone answered it"
    ) func resultAfterExpiryOnlyReplacesWhenSomeoneAnswered() {
        var flow = Self.flow()
        flow.expireIfDue(at: Self.expiresAt)

        // The phone's own word that it expired says what the watch already shows.
        flow.resultArrived(Self.message(
            headline: "Expired",
            detail: "Nothing was logged. Ask ChatGPT again if you still want it.",
            tone: .neutral,
            answeredOn: nil
        ))
        #expect(flow.phase == .expired)

        // But if the wearer answered on the iPhone just before it expired, "Nothing was logged" would be wrong.
        let carriedOut = Self.message(answeredOn: .phone)
        flow.resultArrived(carriedOut)
        #expect(flow.phase == .result(carriedOut))
    }

    @Test("An answer given on the iPhone shows its result on the watch") func resultForAnUnansweredRequest() {
        var flow = Self.flow()
        let result = Self.message(
            headline: "Declined",
            detail: "Nothing was logged.",
            tone: .neutral,
            answeredOn: .phone
        )
        flow.resultArrived(result)

        #expect(flow.phase == .result(result))
        guard case let .result(shown) = flow.phase else {
            Issue.record("Expected a result phase, got \(flow.phase)")
            return
        }
        #expect(shown.answeredOn == .phone)

        // An unanswered request that the phone refused, replaced or withdrew shows the same way.
        var refused = Self.flow()
        let refusal = Self.message(
            headline: "Couldn't log it",
            detail: "Trio hasn't looped in the last 30 minutes.",
            tone: .failure,
            answeredOn: nil
        )
        refused.resultArrived(refusal)
        #expect(refused.phase == .result(refusal))
    }

    @Test("The screen's words, for every phase, exactly") func textForEveryPhase() {
        let now = Self.shownAt.addingTimeInterval(5)
        func text(_ flow: AIRequestWatchFlow, at: Date = now) -> (headline: String, detail: String?) {
            flow.text(at: at, units: "2.10", source: "ChatGPT")
        }

        let approving = text(Self.sending(.approve))
        #expect(approving.headline == "Approving 2.10\u{00A0}U…")
        #expect(approving.detail == nil)

        let waiting = text(Self.sending(.approve, queued: true))
        #expect(waiting.headline == "Waiting for iPhone")
        #expect(waiting.detail == nil)

        let waitingToDecline = text(Self.sending(.decline, queued: true))
        #expect(waitingToDecline.headline == "Waiting for iPhone")
        #expect(waitingToDecline.detail == nil)

        let declining = text(Self.sending(.decline))
        #expect(declining.headline == "Declining…")
        #expect(declining.detail == nil)

        let noReply = text(Self.sending(.approve), at: Self.shownAt.addingTimeInterval(1 + 15))
        #expect(noReply.headline == "No reply from your iPhone yet")
        #expect(noReply.detail == "Check Trio before you bolus yourself.")

        var approved = Self.sending(.approve)
        approved.receiptArrived()
        let approvedText = text(approved)
        #expect(approvedText.headline == "Sent to Trio")
        #expect(approvedText.detail == "Waiting for the result.")

        var declined = Self.sending(.decline)
        declined.receiptArrived()
        let declinedText = text(declined)
        #expect(declinedText.headline == "Declined")
        #expect(declinedText.detail == "Nothing was logged.")

        var notSent = Self.flow()
        notSent.answered(.approve, .notSent, at: now)
        let notSentText = text(notSent)
        #expect(notSentText.headline == "Couldn't send")
        #expect(notSentText.detail == "Answer on your iPhone.")

        var expired = Self.flow()
        expired.expireIfDue(at: Self.expiresAt)
        let expiredText = text(expired, at: Self.expiresAt)
        #expect(expiredText.headline == "Expired")
        #expect(expiredText.detail == "Nothing was logged. Ask ChatGPT again if you still want it.")

        var resulted = Self.sending()
        let result = Self.message()
        resulted.resultArrived(result)
        let resultText = text(resulted)
        #expect(resultText.headline == "Bolus started: 2.10\u{00A0}U")
        #expect(resultText.detail == "35\u{00A0}g carbs logged.")

        // The asking screen lays itself out: it has no headline here.
        let asking = text(Self.flow())
        #expect(asking.headline.isEmpty)
        #expect(asking.detail == nil)
    }
}
