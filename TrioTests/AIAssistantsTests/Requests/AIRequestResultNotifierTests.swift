import Foundation
import Testing
import UserNotifications

@testable import Trio

/// An outcome with the title and amounts of a pizza request.
private func outcome(
    _ report: AIRequestReport,
    askedOn: AIRequestAskedOn? = .watch,
    approvedOn: AIRequestAnswerSide? = nil
) -> AIRequestOutcome {
    AIRequestOutcome(
        id: "r1",
        title: "ChatGPT: slice of pizza",
        source: "ChatGPT",
        shown: AIRequestShown(carbs: "35.00", fat: "10.00", protein: "8.00", units: "2.10"),
        report: report,
        askedOn: askedOn,
        approvedOn: approvedOn,
        declinedOn: nil
    )
}

@Suite("AI request result notifier") struct AIRequestResultNotifierTests {
    @Test func failureAfterApprovalPosts() throws {
        let center = FakeNotificationCenter()
        let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
        notifier.notify(outcome(.failed(reason: "The pump is suspended", carbsLogged: true), approvedOn: .watch))

        let request = try #require(center.added.first)
        #expect(center.added.count == 1)
        #expect(request.identifier == "ai-request-result-r1")
        #expect(request.trigger == nil)
        let content = request.content
        #expect(content.title == "Carbs logged, no bolus")
        #expect(content.subtitle == "ChatGPT: slice of pizza")
        #expect(content.body == "The pump is suspended. Check Trio before you bolus yourself.")
        #expect(content.threadIdentifier == "trio.ai-request")
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.sound == .default)
    }

    @Test func failureWithNothingLoggedSaysSoInTheBody() throws {
        let center = FakeNotificationCenter()
        let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
        notifier.notify(outcome(.failed(reason: "Over your max IOB", carbsLogged: false), approvedOn: .phone))

        let content = try #require(center.added.first?.content)
        #expect(content.title == "Not given")
        #expect(content.body == "Over your max IOB. Nothing was logged.")
    }

    @Test func failureApprovedOnEitherSidePosts() {
        for side in [AIRequestAnswerSide.watch, .phone] {
            let center = FakeNotificationCenter()
            let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
            notifier.notify(outcome(.failed(reason: "No", carbsLogged: false), approvedOn: side))
            #expect(center.added.count == 1)
        }
    }

    @Test func successDoesNotPost() {
        let center = FakeNotificationCenter()
        let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
        let shown = AIRequestShown(carbs: "35.00", fat: "10.00", protein: "8.00", units: "2.10")
        notifier.notify(outcome(.delivering(shown: shown), approvedOn: .watch))
        notifier.notify(outcome(.logged(shown: shown), approvedOn: .phone))
        #expect(center.added.isEmpty)
    }

    @Test func refusalWithoutApprovalDoesNotPost() {
        let center = FakeNotificationCenter()
        let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
        // Refused on arrival: it was never asked, so nobody approved it.
        notifier.notify(outcome(.failed(reason: "Over your max IOB", carbsLogged: false), askedOn: nil))
        // Asked, then refused with no approval.
        notifier.notify(outcome(.failed(reason: "Over your max IOB", carbsLogged: false)))
        #expect(center.added.isEmpty)
    }

    @Test func otherEndingsDoNotPost() {
        let center = FakeNotificationCenter()
        let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
        notifier.notify(outcome(.declined(on: .phone)))
        notifier.notify(outcome(.expired))
        notifier.notify(outcome(.replaced))
        notifier.notify(outcome(.withdrawn))
        #expect(center.added.isEmpty)
    }

    @Test func failureShownOnTheSheetDoesNotPost() {
        let center = FakeNotificationCenter()
        let asked = TestBox<[String]>([])
        let notifier = AIRequestResultNotifier(center: center, isShowing: { id in
            asked.value.append(id)
            return true
        })
        notifier.notify(outcome(.failed(reason: "No", carbsLogged: false), approvedOn: .phone))
        #expect(center.added.isEmpty)
        #expect(asked.value == ["r1"])
    }

    // MARK: The runtime's notifier: the sheet shows a request only while Trio is in front

    private func runtimeNotifier(
        center: FakeNotificationCenter,
        presentedID: String?,
        isAppActive: Bool
    ) -> AIRequestResultNotifier {
        AIRequestsRuntime.makeNotifier(center: center, presentedID: { presentedID }, isAppActive: { isAppActive })
    }

    @Test func failureIsSuppressedWhileTheSheetShowsItInFront() {
        let center = FakeNotificationCenter()
        let notifier = runtimeNotifier(center: center, presentedID: "r1", isAppActive: true)
        notifier.notify(outcome(.failed(reason: "No", carbsLogged: false), approvedOn: .phone))
        #expect(center.added.isEmpty)
    }

    @Test func failureIsPostedWhenTheSheetIsPresentedButTrioIsNotInFront() {
        // The wearer approved, then locked the phone or switched apps: the sheet is still presented, behind them.
        let center = FakeNotificationCenter()
        let notifier = runtimeNotifier(center: center, presentedID: "r1", isAppActive: false)
        notifier.notify(outcome(.failed(reason: "No", carbsLogged: true), approvedOn: .phone))
        #expect(center.added.count == 1)
        #expect(center.added.first?.identifier == "ai-request-result-r1")
    }

    @Test func failureIsPostedWhenTrioIsInFrontButTheSheetIsNotPresented() {
        let center = FakeNotificationCenter()
        let notifier = runtimeNotifier(center: center, presentedID: nil, isAppActive: true)
        notifier.notify(outcome(.failed(reason: "No", carbsLogged: false), approvedOn: .watch))
        #expect(center.added.count == 1)
    }

    @Test func failureIsPostedWhenTheSheetShowsAnotherRequest() {
        let center = FakeNotificationCenter()
        let notifier = runtimeNotifier(center: center, presentedID: "r2", isAppActive: true)
        notifier.notify(outcome(.failed(reason: "No", carbsLogged: false), approvedOn: .phone))
        #expect(center.added.count == 1)
    }

    @Test func sheetIsNotAskedAboutAnOutcomeThatNeverPosts() {
        let asked = TestBox<[String]>([])
        let notifier = AIRequestResultNotifier(center: FakeNotificationCenter(), isShowing: { id in
            asked.value.append(id)
            return false
        })
        notifier.notify(outcome(.expired))
        #expect(asked.value.isEmpty)
    }

    /// The runtime's route for each outcome: the watch hears the result of a request it was asked, and the notifier
    /// hears all of them.
    @Test func outcomeReachesTheWatchOnlyWhenItWasAskedThere() throws {
        let center = FakeNotificationCenter()
        let session = FakeWatchSession()
        session.isReachable = true
        let link = AIRequestWatchLink(
            session: session,
            keys: AIRequestKeyStore(keychain: InMemoryAIRequestKeychain()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            onAnswer: { _ in },
            onViewing: { _ in },
            onWatchTokenChanged: {}
        )
        let notifier = AIRequestResultNotifier(center: center, isShowing: { _ in false })
        let failure = AIRequestReport.failed(reason: "No", carbsLogged: false)

        AIRequestsRuntime.publish(outcome(failure, askedOn: .phone, approvedOn: .phone), to: link, notifier: notifier)
        #expect(session.messages.isEmpty && session.userInfos.isEmpty)
        #expect(center.added.count == 1)

        AIRequestsRuntime.publish(outcome(failure, askedOn: nil), to: link, notifier: notifier)
        #expect(session.messages.isEmpty && session.userInfos.isEmpty)

        AIRequestsRuntime.publish(outcome(failure, askedOn: .watch, approvedOn: .watch), to: link, notifier: notifier)
        let sent = try #require(session.messages.first?[AIRequestIdentifiers.keyResult] as? Data)
        let message = try JSONDecoder().decode(AIRequestResultMessage.self, from: sent)
        #expect(message.id == "r1" && message.headline == "Not given" && message.answeredOn == .watch)
        #expect(session.userInfos.count == 1)
        #expect(center.added.count == 2)
    }
}
