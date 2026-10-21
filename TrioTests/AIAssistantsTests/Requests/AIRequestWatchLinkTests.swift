import Foundation
import Testing

@testable import Trio

/// Records what the link sends to the watch, in place of the WatchConnectivity session.
final class FakeWatchSession: AIRequestWatchSession {
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = false
    private(set) var messages: [[String: Any]] = []
    private(set) var userInfos: [[String: Any]] = []

    func sendMessage(_ message: [String: Any]) {
        messages.append(message)
    }

    func queueUserInfo(_ userInfo: [String: Any]) {
        userInfos.append(userInfo)
    }
}

/// What the link told its owner, in order.
private final class LinkEvents {
    var answers: [AIRequestAnswer] = []
    var viewed: [String] = []
    var tokenChanges = 0
}

private func makeLink(
    session: FakeWatchSession = FakeWatchSession(),
    keys: AIRequestKeyStore = AIRequestKeyStore(keychain: InMemoryAIRequestKeychain()),
    defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
    events: LinkEvents = LinkEvents()
) -> AIRequestWatchLink {
    AIRequestWatchLink(
        session: session,
        keys: keys,
        defaults: defaults,
        onAnswer: { events.answers.append($0) },
        onViewing: { events.viewed.append($0) },
        onWatchTokenChanged: { events.tokenChanges += 1 }
    )
}

/// Push tokens as the watch sends them: hex, 32 bytes.
private let watchToken = String(repeating: "ab", count: 32)
private let otherWatchToken = String(repeating: "cd", count: 32)

private let samplePrompt = AIRequestPrompt(
    id: "r1",
    source: "ChatGPT",
    description: "slice of pizza",
    shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 1.2),
    title: "ChatGPT: slice of pizza",
    body: "20 g carbs · 1.2 U",
    expiresAt: Date(timeIntervalSince1970: 1_792_000_300),
    approvalStyle: .twoStep,
    answerRoute: .both,
    answerToken: nil,
    answerURL: nil
)

private let sampleAnswer = AIRequestSigner.sign(
    prompt: samplePrompt,
    decision: .approve,
    declinedBy: nil,
    at: Date(timeIntervalSince1970: 1_792_000_010),
    key: Data(0 ..< 32)
)

@Suite("AI request watch link") struct AIRequestWatchLinkTests {
    @Test func keyRequestRotatesAndSendsTheKey() throws {
        let session = FakeWatchSession()
        let keys = AIRequestKeyStore(keychain: InMemoryAIRequestKeychain())
        let link = makeLink(session: session, keys: keys)

        #expect(link.receive([AIRequestIdentifiers.keyRequest: true]))
        let first = try #require(session.userInfos.last?[AIRequestIdentifiers.keyMessage] as? String)
        #expect(Data(base64Encoded: first) == keys.current)
        #expect(session.messages.isEmpty)

        // A reinstalled watch asks again, and the old key stops verifying.
        #expect(link.receive([AIRequestIdentifiers.keyRequest: true]))
        let second = try #require(session.userInfos.last?[AIRequestIdentifiers.keyMessage] as? String)
        #expect(second != first)
        #expect(Data(base64Encoded: second) == keys.current)
        #expect(session.userInfos.count == 2)
    }

    @Test func keyRequestWithoutAStoredKeySendsNothing() {
        let session = FakeWatchSession()
        let keychain = InMemoryAIRequestKeychain()
        keychain.failWrites = true
        let keys = AIRequestKeyStore(keychain: keychain)
        let link = makeLink(session: session, keys: keys)

        #expect(link.receive([AIRequestIdentifiers.keyRequest: true]))
        #expect(session.userInfos.isEmpty && session.messages.isEmpty)
        #expect(keys.current == nil)
    }

    @Test func answerIsDecodedAndForwarded() throws {
        let events = LinkEvents()
        let link = makeLink(events: events)
        let data = try JSONEncoder().encode(sampleAnswer)

        #expect(link.receive([AIRequestIdentifiers.keyAnswer: data]))
        #expect(events.answers == [sampleAnswer])
    }

    @Test func unreadableAnswerIsHandledButNotForwarded() {
        let events = LinkEvents()
        let link = makeLink(events: events)

        #expect(link.receive([AIRequestIdentifiers.keyAnswer: Data("not json".utf8)]))
        #expect(link.receive([AIRequestIdentifiers.keyAnswer: "not data"]))
        #expect(events.answers.isEmpty)
    }

    @Test func watchTokenStoredAndChangeReportedOnce() {
        let session = FakeWatchSession()
        let events = LinkEvents()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let link = makeLink(session: session, defaults: defaults, events: events)
        #expect(link.watchPushToken == nil)
        #expect(!link.isWatchAvailable)

        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: watchToken]))
        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: watchToken]))
        #expect(link.watchPushToken == watchToken)
        #expect(defaults.string(forKey: "AIAssistants.watchPushToken") == watchToken)
        #expect(events.tokenChanges == 1)
        #expect(link.isWatchAvailable)

        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: otherWatchToken]))
        #expect(events.tokenChanges == 2)
        #expect(link.watchPushToken == otherWatchToken)
    }

    @Test func emptyWatchTokenIsIgnored() {
        let events = LinkEvents()
        let link = makeLink(events: events)

        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: ""]))
        #expect(link.watchPushToken == nil)
        #expect(events.tokenChanges == 0)
    }

    /// The service registers a watch token only as 64 to 200 hex digits.
    @Test(arguments: [
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 201),
        String(repeating: "zz", count: 32),
        String(repeating: "ab", count: 32) + "\n",
        String(repeating: "\u{FF41}", count: 64) // fullwidth "a"
    ]) func malformedWatchTokenIsIgnored(token: String) {
        let events = LinkEvents()
        let link = makeLink(events: events)
        _ = link.receive([AIRequestIdentifiers.keyWatchPushToken: watchToken])

        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: token]))
        #expect(link.watchPushToken == watchToken)
        #expect(events.tokenChanges == 1)
    }

    @Test func watchTokenIsStoredInLowerCase() {
        let events = LinkEvents()
        let link = makeLink(events: events)

        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: String(repeating: "AB", count: 100)]))
        #expect(link.watchPushToken == String(repeating: "ab", count: 100))
        // The same token in lower case isn't a change.
        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: String(repeating: "ab", count: 100)]))
        #expect(events.tokenChanges == 1)
    }

    @Test func watchTokenSurvivesANewLink() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        _ = makeLink(defaults: defaults).receive([AIRequestIdentifiers.keyWatchPushToken: watchToken])

        #expect(makeLink(defaults: defaults).watchPushToken == watchToken)
    }

    @Test func watchIsAvailableOnlyWhenPairedInstalledAndHasAToken() {
        let session = FakeWatchSession()
        let link = makeLink(session: session)
        _ = link.receive([AIRequestIdentifiers.keyWatchPushToken: watchToken])
        #expect(link.isWatchAvailable)

        session.isPaired = false
        #expect(!link.isWatchAvailable)
        session.isPaired = true
        session.isWatchAppInstalled = false
        #expect(!link.isWatchAvailable)
    }

    @Test func unrelatedMessagesAreLeftAlone() {
        let session = FakeWatchSession()
        let events = LinkEvents()
        let link = makeLink(session: session, events: events)

        #expect(!link.receive(["bolus": 1.0]))
        #expect(!link.receive([:]))
        #expect(session.userInfos.isEmpty && session.messages.isEmpty)
        #expect(events.answers.isEmpty && events.tokenChanges == 0)
    }

    @Test func deliverUsesSendMessageWhenReachableElseUserInfo() throws {
        let session = FakeWatchSession()
        let link = makeLink(session: session)

        session.isReachable = true
        link.deliver(samplePrompt)
        #expect(session.messages.count == 1 && session.userInfos.isEmpty)
        let sent = try #require(session.messages.first?[AIRequestIdentifiers.keyPrompt] as? Data)
        #expect(try JSONDecoder().decode(AIRequestPrompt.self, from: sent) == samplePrompt)

        session.isReachable = false
        link.deliver(samplePrompt)
        #expect(session.messages.count == 1 && session.userInfos.count == 1)
        let queued = try #require(session.userInfos.first?[AIRequestIdentifiers.keyPrompt] as? Data)
        #expect(try JSONDecoder().decode(AIRequestPrompt.self, from: queued) == samplePrompt)
    }

    @Test func withdrawUsesSendMessageWhenReachableElseUserInfo() {
        let session = FakeWatchSession()
        let link = makeLink(session: session)

        session.isReachable = true
        link.withdraw(id: "r1")
        #expect(session.messages.count == 1 && session.userInfos.isEmpty)
        #expect(session.messages.first?[AIRequestIdentifiers.keyWithdraw] as? String == "r1")

        session.isReachable = false
        link.withdraw(id: "r2")
        #expect(session.messages.count == 1 && session.userInfos.count == 1)
        #expect(session.userInfos.first?[AIRequestIdentifiers.keyWithdraw] as? String == "r2")
    }

    @Test func sendResultQueuesAndSendsLive() throws {
        let session = FakeWatchSession()
        session.isReachable = true
        let link = makeLink(session: session)
        let message = AIRequestResultMessage(
            id: "r1",
            title: "ChatGPT: slice of pizza",
            headline: "Bolus started: 2.10\u{00A0}U",
            detail: "35\u{00A0}g carbs logged.",
            tone: .success,
            answeredOn: .watch
        )

        link.sendResult(message)

        #expect(session.userInfos.count == 1 && session.messages.count == 1)
        let queued = try #require(session.userInfos.first?[AIRequestIdentifiers.keyResult] as? Data)
        let live = try #require(session.messages.first?[AIRequestIdentifiers.keyResult] as? Data)
        #expect(try JSONDecoder().decode(AIRequestResultMessage.self, from: queued) == message)
        #expect(try JSONDecoder().decode(AIRequestResultMessage.self, from: live) == message)
        #expect(session.userInfos.first?.count == 1 && session.messages.first?.count == 1)
    }

    @Test func sendResultOnlyQueuesWhenTheWatchIsNotReachable() throws {
        let session = FakeWatchSession()
        session.isReachable = false
        let link = makeLink(session: session)

        link.sendResult(AIRequestResultMessage(
            id: "r1",
            title: "ChatGPT: slice of pizza",
            headline: "Declined",
            detail: "Nothing was logged.",
            tone: .neutral,
            answeredOn: .watch
        ))

        #expect(session.messages.isEmpty)
        let queued = try #require(session.userInfos.first?[AIRequestIdentifiers.keyResult] as? Data)
        #expect(try JSONDecoder().decode(AIRequestResultMessage.self, from: queued).id == "r1")
    }

    @Test func viewingMessageCallsOnViewing() {
        let events = LinkEvents()
        let session = FakeWatchSession()
        let link = makeLink(session: session, events: events)

        #expect(link.receive([AIRequestIdentifiers.keyViewing: "r1"]))
        #expect(events.viewed == ["r1"])
        // Nothing is sent back, and the other callbacks are left alone.
        #expect(session.messages.isEmpty && session.userInfos.isEmpty)
        #expect(events.answers.isEmpty && events.tokenChanges == 0)
    }

    @Test func viewingMessageWithoutAnIDIsHandledButNotForwarded() {
        let events = LinkEvents()
        let link = makeLink(events: events)

        #expect(link.receive([AIRequestIdentifiers.keyViewing: 7]))
        #expect(events.viewed.isEmpty)
    }

    @Test func messagesHeldBeforeTheRuntimeAreReplayed() throws {
        let holder = AIRequestMessageHolder()
        let answer: [String: Any] = [AIRequestIdentifiers.keyAnswer: try JSONEncoder().encode(sampleAnswer)]
        let token: [String: Any] = [AIRequestIdentifiers.keyWatchPushToken: "abc123"]
        let keyRequest: [String: Any] = [AIRequestIdentifiers.keyRequest: true]

        #expect(holder.handle(answer))
        #expect(holder.handle(token))

        var received: [[String: Any]] = []
        holder.install { received.append($0)
            return true }
        #expect(received.count == 2)
        #expect(received[0][AIRequestIdentifiers.keyAnswer] as? Data == answer[AIRequestIdentifiers.keyAnswer] as? Data)
        #expect(received[1][AIRequestIdentifiers.keyWatchPushToken] as? String == "abc123")

        // Once the receiver is set, messages go straight to it and nothing is replayed twice.
        #expect(holder.handle(keyRequest))
        #expect(received.count == 3)
        holder.install { received.append($0)
            return true }
        #expect(received.count == 3)
    }

    @Test func messageArrivingDuringTheReplayKeepsItsPlace() {
        let holder = AIRequestMessageHolder()
        let first: [String: Any] = [AIRequestIdentifiers.keyWatchPushToken: "first"]
        let second: [String: Any] = [AIRequestIdentifiers.keyWatchPushToken: "second"]
        let third: [String: Any] = [AIRequestIdentifiers.keyWatchPushToken: "third"]
        #expect(holder.handle(first))
        #expect(holder.handle(second))

        var received: [String] = []
        holder.install { message in
            received.append(message[AIRequestIdentifiers.keyWatchPushToken] as? String ?? "")
            if received.count == 1 {
                #expect(holder.handle(third))
            }
            return true
        }
        #expect(received == ["first", "second", "third"])
    }

    @Test func unownedMessagesAreNotHeld() {
        let holder = AIRequestMessageHolder()
        #expect(!holder.handle(["bolus": 1.0]))
        #expect(!holder.handle([:]))

        var received: [[String: Any]] = []
        holder.install { received.append($0)
            return true }
        #expect(received.isEmpty)

        // The hook, whose holder has no receiver until the service builds the runtime, leaves them alone too.
        #expect(!AIRequestHooks.phoneReceivedFromWatch(["bolus": 1.0]))
    }
}
