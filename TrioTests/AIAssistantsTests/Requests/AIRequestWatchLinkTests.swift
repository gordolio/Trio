import Combine
import Foundation
import Testing

@testable import Trio

/// Records what the link sends to the watch, in place of the WatchConnectivity session.
final class FakeWatchSession: AIRequestWatchSession {
    /// The relay sends from the main queue and from tasks, while a test reads.
    private let lock = NSLock()
    private var sentMessages: [[String: Any]] = []
    private var queuedUserInfos: [[String: Any]] = []

    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = false

    var messages: [[String: Any]] { lock.withLock { sentMessages } }
    var userInfos: [[String: Any]] { lock.withLock { queuedUserInfos } }

    func sendMessage(_ message: [String: Any]) {
        lock.withLock { sentMessages.append(message) }
    }

    func queueUserInfo(_ userInfo: [String: Any]) {
        lock.withLock { queuedUserInfos.append(userInfo) }
    }
}

/// What the link told its owner, in order.
private final class LinkEvents {
    var opened: [String] = []
    var confirms: [AIRequestWatchConfirm] = []
    var closes: [AIRequestWatchClose] = []
    var tokenChanges = 0
}

private func makeLink(
    session: FakeWatchSession = FakeWatchSession(),
    defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
    events: LinkEvents = LinkEvents(),
    allowsMealRequests: @escaping () -> Bool = { false }
) -> AIRequestWatchLink {
    AIRequestWatchLink(
        session: session,
        defaults: defaults,
        allowsMealRequests: allowsMealRequests,
        onOpen: { events.opened.append($0) },
        onConfirm: { events.confirms.append($0) },
        onClose: { events.closes.append($0) },
        onWatchTokenChanged: { events.tokenChanges += 1 }
    )
}

/// What the watch was told about meal requests being allowed, sent live or queued, in order.
private func mealRequestsAllowedSent(_ session: FakeWatchSession) -> [Bool] {
    (session.messages + session.userInfos).compactMap { $0[AIRequestIdentifiers.keyMealRequestsAllowed] as? Bool }
}

/// Push tokens as the watch sends them: hex, 32 bytes.
private let watchToken = String(repeating: "ab", count: 32)
private let otherWatchToken = String(repeating: "cd", count: 32)

private func d(_ text: String) -> Decimal {
    Decimal(string: text)!
}

/// An acknowledgement as the watch receives it.
private struct SentAcknowledgment: Equatable {
    let acknowledged: Bool
    let message: String
    let ackCode: String
}

/// The acknowledgements the watch had been sent when a report reached trio-rc.
private final class AcknowledgmentsAtReport: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledgments: [SentAcknowledgment]?

    var recorded: [SentAcknowledgment]? { lock.withLock { acknowledgments } }

    func record(_ sent: [SentAcknowledgment]) {
        lock.withLock { acknowledgments = sent }
    }
}

/// The runtime's link to the watch and its relay over a coordinator over fakes, with the fake session in place of
/// WatchConnectivity.
private final class RelayRig {
    let harness: CoordinatorHarness
    let session = FakeWatchSession()
    let relay = WatchRelay()
    let link: AIRequestWatchLink

    init(reachable: Bool = true) {
        harness = makeCoordinator()
        session.isReachable = reachable
        link = AIRequestsRuntime.makeWatchLink(
            session: session,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            relay: relay,
            allowsMealRequests: { true },
            onWatchTokenChanged: {}
        )
        relay.connect(coordinator: harness.coordinator, link: link)
    }

    /// The request is pending for the wearer, as when the assistant asked.
    func ask(_ id: String, carbs: Decimal = 20) async {
        await harness.coordinator.receive(meal(id: id, carbs: carbs), via: .service)
    }

    /// Every message sent live, then every one queued, read as `key`'s JSON.
    func sent<Message: Decodable>(_ key: String, as _: Message.Type) throws -> [Message] {
        try (session.messages + session.userInfos).compactMap { $0[key] as? Data }
            .map { try JSONDecoder().decode(Message.self, from: $0) }
    }

    /// The acknowledgements sent, in order.
    var acknowledgments: [SentAcknowledgment] {
        (session.messages + session.userInfos).compactMap { sent in
            guard let acknowledged = sent[WatchMessageKeys.acknowledged] as? Bool,
                  let message = sent[WatchMessageKeys.message] as? String,
                  let ackCode = sent[WatchMessageKeys.ackCode] as? String
            else { return nil }
            return SentAcknowledgment(acknowledged: acknowledged, message: message, ackCode: ackCode)
        }
    }

    /// The `AIRequestEnded` messages sent, in order.
    func ended() throws -> [AIRequestEnded] {
        try sent(AIRequestIdentifiers.keyEnded, as: AIRequestEnded.self)
    }
}

@Suite("AI request watch link") struct AIRequestWatchLinkTests {
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

    @Test func watchTokenIsAnsweredWithWhetherMealRequestsAreAllowed() {
        // The watch sends its token each time it launches. It asks to show notifications only once meal requests are on.
        let session = FakeWatchSession()
        let allowed = TestBox(false)
        let link = makeLink(session: session, allowsMealRequests: { allowed.value })
        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: watchToken]))
        allowed.value = true
        #expect(link.receive([AIRequestIdentifiers.keyWatchPushToken: watchToken]))
        #expect(mealRequestsAllowedSent(session) == [false, true])
    }

    @Test func turningMealRequestsOnOrOffTellsTheWatch() {
        let session = FakeWatchSession()
        let link = makeLink(session: session)
        let preferences = CurrentValueSubject<AIAssistantsPreferences, Never>(AIAssistantsPreferences())
        link.follow(preferences.eraseToAnyPublisher())
        // The current value isn't sent: the watch hears it when it sends its token.
        #expect(mealRequestsAllowedSent(session).isEmpty)

        preferences.send(AIAssistantsPreferences(phoneBackupDelay: 30))
        preferences.send(AIAssistantsPreferences(allowsMealRequests: true))
        preferences.send(AIAssistantsPreferences(allowsMealRequests: true, phoneBackupDelay: 60))
        preferences.send(AIAssistantsPreferences())
        #expect(mealRequestsAllowedSent(session) == [true, false])
    }

    @Test func unrelatedMessagesAreLeftAlone() {
        let session = FakeWatchSession()
        let events = LinkEvents()
        let link = makeLink(session: session, events: events)

        #expect(!link.receive(["bolus": 1.0]))
        #expect(!link.receive([:]))
        #expect(session.userInfos.isEmpty && session.messages.isEmpty)
        #expect(events.opened.isEmpty && events.confirms.isEmpty && events.closes.isEmpty && events.tokenChanges == 0)
    }

    @Test func theOldDesignsMessagesAreNeitherHandledNorHeld() {
        // A watch from an earlier build may still send these. Nothing reads them any more, so they are left to the
        // watch manager, which ignores what it doesn't know.
        let old: [[String: Any]] = [
            ["aiRequestKeyRequest": true],
            ["aiRequestAnswer": Data("{}".utf8)],
            ["aiRequestViewing": "r1"]
        ]
        let link = makeLink()
        let holder = AIRequestMessageHolder()
        for message in old {
            #expect(!link.receive(message))
            #expect(!holder.handle(message))
        }
    }

    @Test func messagesHeldBeforeTheRuntimeAreReplayed() throws {
        let holder = AIRequestMessageHolder()
        let confirm = AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)
        let confirmed: [String: Any] = [AIRequestIdentifiers.keyConfirm: try JSONEncoder().encode(confirm)]
        let token: [String: Any] = [AIRequestIdentifiers.keyWatchPushToken: "abc123"]
        let open: [String: Any] = [AIRequestIdentifiers.keyOpen: "r1"]

        #expect(holder.handle(confirmed))
        #expect(holder.handle(token))

        var received: [[String: Any]] = []
        holder.install { received.append($0)
            return true }
        #expect(received.count == 2)
        #expect(
            received[0][AIRequestIdentifiers.keyConfirm] as? Data == confirmed[AIRequestIdentifiers.keyConfirm] as? Data
        )
        #expect(received[1][AIRequestIdentifiers.keyWatchPushToken] as? String == "abc123")

        // Once the receiver is set, messages go straight to it and nothing is replayed twice.
        #expect(holder.handle(open))
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

    // MARK: The watch's open, confirm and close messages

    @Test func openMessageIsForwardedWithItsRequestID() {
        let events = LinkEvents()
        let session = FakeWatchSession()
        let link = makeLink(session: session, events: events)

        #expect(link.receive([AIRequestIdentifiers.keyOpen: "r1"]))
        #expect(events.opened == ["r1"])
        // The link only passes it on: whatever comes of it is sent by the relay.
        #expect(session.messages.isEmpty && session.userInfos.isEmpty)
        #expect(events.confirms.isEmpty && events.closes.isEmpty && events.tokenChanges == 0)
    }

    @Test func openMessageWithoutAnIDIsHandledButNotForwarded() {
        let events = LinkEvents()
        let link = makeLink(events: events)

        #expect(link.receive([AIRequestIdentifiers.keyOpen: 7]))
        #expect(events.opened.isEmpty)
    }

    @Test func confirmMessageIsDecodedAndForwarded() throws {
        let events = LinkEvents()
        let link = makeLink(events: events)
        let exact = AIRequestWatchConfirm(id: "r1", units: d("2.15"), carbs: nil)
        let changed = AIRequestWatchConfirm(id: "r2", units: 0, carbs: 80)

        #expect(link.receive([AIRequestIdentifiers.keyConfirm: try JSONEncoder().encode(exact)]))
        #expect(link.receive([AIRequestIdentifiers.keyConfirm: try JSONEncoder().encode(changed)]))
        #expect(events.confirms == [exact, changed])
    }

    @Test func closeMessageIsDecodedAndForwarded() throws {
        let events = LinkEvents()
        let link = makeLink(events: events)
        let left = AIRequestWatchClose(id: "r1", dismissed: false)
        let swiped = AIRequestWatchClose(id: "r2", dismissed: true)

        #expect(link.receive([AIRequestIdentifiers.keyClose: try JSONEncoder().encode(left)]))
        #expect(link.receive([AIRequestIdentifiers.keyClose: try JSONEncoder().encode(swiped)]))
        #expect(events.closes == [left, swiped])
    }

    @Test func unreadableConfirmAndCloseAreHandledButNotForwarded() {
        let events = LinkEvents()
        let link = makeLink(events: events)

        #expect(link.receive([AIRequestIdentifiers.keyConfirm: Data("not json".utf8)]))
        #expect(link.receive([AIRequestIdentifiers.keyConfirm: "not data"]))
        #expect(link.receive([AIRequestIdentifiers.keyClose: Data("not json".utf8)]))
        #expect(link.receive([AIRequestIdentifiers.keyClose: "not data"]))
        #expect(events.confirms.isEmpty && events.closes.isEmpty)
    }

    @Test func detailsEndedAndAcknowledgmentSendLiveWhenReachable() throws {
        let session = FakeWatchSession()
        session.isReachable = true
        let link = makeLink(session: session)
        let details = AIRequestWatchDetails(
            id: "r1",
            carbs: d("82.5"),
            fat: 10,
            protein: 5,
            units: d("2.15"),
            expiresAt: Date(timeIntervalSince1970: 1_792_000_300)
        )
        let ended = AIRequestEnded(id: "r1", headline: "Logged on your iPhone", isSuccess: true)

        link.sendDetails(details)
        link.sendEnded(ended)
        link.sendAcknowledgment(success: true, message: "Bolus enacted successfully.")

        #expect(session.userInfos.isEmpty && session.messages.count == 3)
        let sentDetails = try #require(session.messages[0][AIRequestIdentifiers.keyDetails] as? Data)
        #expect(try JSONDecoder().decode(AIRequestWatchDetails.self, from: sentDetails) == details)
        let sentEnded = try #require(session.messages[1][AIRequestIdentifiers.keyEnded] as? Data)
        #expect(try JSONDecoder().decode(AIRequestEnded.self, from: sentEnded) == ended)
        // Upstream's acknowledgement, which the watch's own acknowledgement screen shows.
        let ack = session.messages[2]
        #expect(ack.count == 3)
        #expect(ack[WatchMessageKeys.acknowledged] as? Bool == true)
        #expect(ack[WatchMessageKeys.message] as? String == "Bolus enacted successfully.")
        #expect(ack[WatchMessageKeys.ackCode] as? String == "success")
    }

    @Test func failedAcknowledgmentHasTheFailureCode() {
        let session = FakeWatchSession()
        session.isReachable = true
        let link = makeLink(session: session)

        link.sendAcknowledgment(success: false, message: "Pump suspended")

        let ack = session.messages.first
        #expect(ack?[WatchMessageKeys.acknowledged] as? Bool == false)
        #expect(ack?[WatchMessageKeys.message] as? String == "Pump suspended")
        #expect(ack?[WatchMessageKeys.ackCode] as? String == "failure")
    }

    @Test func messagesQueueWhenUnreachable() throws {
        let session = FakeWatchSession()
        session.isReachable = false
        let link = makeLink(session: session)

        link.sendDetails(AIRequestWatchDetails(
            id: "r1",
            carbs: 20,
            fat: 10,
            protein: 8,
            units: d("1.2"),
            expiresAt: Date(timeIntervalSince1970: 1_792_000_300)
        ))
        link.sendEnded(AIRequestEnded(id: "r1", headline: "Expired", isSuccess: false))
        link.sendAcknowledgment(success: false, message: "Logged on your iPhone")

        #expect(session.messages.isEmpty)
        #expect(session.userInfos.count == 3)
        #expect(session.userInfos[0][AIRequestIdentifiers.keyDetails] is Data)
        #expect(session.userInfos[1][AIRequestIdentifiers.keyEnded] is Data)
        #expect(session.userInfos[2][WatchMessageKeys.acknowledged] as? Bool == false)
        #expect(session.userInfos[2][WatchMessageKeys.ackCode] as? String == "failure")
    }

    // MARK: The relay between the watch's messages and the coordinator

    @Test func openMessageRepliesWithDetails() async throws {
        let rig = RelayRig()
        await rig.harness.coordinator.receive(meal(id: "r1", carbs: d("82.5"), fat: 10, protein: 5), via: .service)
        rig.harness.treatments.doseResult = AIRequestDose(units: d("2.157"))

        await rig.relay.open("r1")

        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self) == [AIRequestWatchDetails(
            id: "r1",
            carbs: d("82.5"),
            fat: 10,
            protein: 5,
            units: d("2.15"),
            expiresAt: coordinatorTestStart + 5 * 60
        )])
        #expect(rig.session.userInfos.isEmpty)
    }

    @Test func openForAnotherRequestSendsNoDetails() async throws {
        let rig = RelayRig()
        await rig.ask("r1")

        await rig.relay.open("r2")

        // The relay has no ending for it, so it ended before Trio launched: nothing was logged for it.
        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).isEmpty)
        #expect(try rig.ended() == [AIRequestEnded(id: "r2", headline: "Expired", isSuccess: false)])
        #expect(rig.harness.coordinator.current.value?.request.id == "r1")
    }

    @Test func openOfARequestTrioHasntSeenChecksInFirst() async throws {
        let rig = RelayRig()
        let checkIns = CallCounter()
        rig.relay.checkInBeforeOpening { [rig] in
            checkIns.record()
            await rig.ask("r1")
        }

        await rig.relay.open("r1")

        #expect(checkIns.calls == 1)
        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).map(\.id) == ["r1"])
        #expect(try rig.ended().isEmpty)
    }

    @Test func theWatchAskingAgainForTheSameRequestJoinsTheOpenInFlight() async throws {
        let rig = RelayRig()
        let checkIns = CallCounter()
        let gate = UploadGate()
        rig.relay.checkInBeforeOpening { [rig] in
            checkIns.record()
            await gate.wait()
            await rig.ask("r1")
        }

        let first = Task { await rig.relay.open("r1") }
        #expect(await eventuallyTrue { checkIns.calls == 1 })
        let again = Task { await rig.relay.open("r1") }
        gate.open()
        await first.value
        await again.value

        #expect(checkIns.calls == 1)
        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).map(\.id) == ["r1"])
    }

    @Test func openOfARequestTheServiceDoesntHaveEitherRepliesExpired() async throws {
        let rig = RelayRig()
        let checkIns = CallCounter()
        rig.relay.checkInBeforeOpening { checkIns.record() }

        await rig.relay.open("r9")

        #expect(checkIns.calls == 1)
        #expect(try rig.ended() == [AIRequestEnded(id: "r9", headline: "Expired", isSuccess: false)])
    }

    @Test func openForAnEndedRequestRepliesWithItsEnding() async throws {
        let rig = RelayRig()
        await rig.ask("r1")
        await rig.harness.coordinator.close(id: "r1", on: .phone, dismissed: false)
        // The decline's own ending reaches the watch from the main queue.
        #expect(await eventuallyTrue { ((try? rig.ended().count) ?? 0) == 1 })
        await rig.ask("r2")
        await rig.relay.confirm(AIRequestWatchConfirm(id: "r2", units: d("1.2"), carbs: nil))

        // The wearer opens them again from their old notifications, and one Trio doesn't know.
        await rig.relay.open("r1")
        await rig.relay.open("r2")
        await rig.relay.open("r9")

        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).isEmpty)
        #expect(try rig.ended() == [
            AIRequestEnded(id: "r1", headline: "Declined on your iPhone", isSuccess: false),
            AIRequestEnded(id: "r1", headline: "Declined on your iPhone", isSuccess: false),
            AIRequestEnded(id: "r2", headline: "Logged on your watch", isSuccess: true),
            AIRequestEnded(id: "r9", headline: "Expired", isSuccess: false)
        ])
    }

    @Test func openAfterExpiryRepliesExpired() async throws {
        let rig = RelayRig()
        await rig.ask("r1")
        rig.harness.now = coordinatorTestStart + 5 * 60

        await rig.relay.open("r1")

        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).isEmpty)
        // The open's own reply, and the expiry's ending from the main queue, in either order.
        #expect(await eventuallyTrue { ((try? rig.ended().count) ?? 0) == 2 })
        let expired = AIRequestEnded(id: "r1", headline: "Expired", isSuccess: false)
        #expect(try rig.ended() == [expired, expired])
        #expect(rig.harness.reporter.states == ["r1:pending", "r1:expired"])
    }

    @Test func confirmCarriesOutAndAcknowledges() async {
        let rig = RelayRig()
        await rig.ask("r1")

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))

        #expect(rig.harness.treatments.storedCarbs == [StoredCarbs(id: "r1", carbs: 20, fat: 10, protein: 8)])
        #expect(rig.harness.treatments.enacted == [d("1.2")])
        #expect(rig.session.messages.count == 1)
        let ack = rig.session.messages.first
        #expect(ack?[WatchMessageKeys.acknowledged] as? Bool == true)
        #expect(ack?[WatchMessageKeys.message] as? String == "Bolus enacted successfully.")
        #expect(ack?[WatchMessageKeys.ackCode] as? String == "success")
    }

    @Test func confirmIsAcknowledgedBeforeItsReportGoesToTrioRC() async {
        // The report to trio-rc can wait on the network. The watch hears how it went first, as upstream's watch does.
        let rig = RelayRig()
        await rig.ask("r1")
        let atReport = AcknowledgmentsAtReport()
        rig.harness.reporter.whileReporting = { [rig] report in
            if report.state == .delivering {
                atReport.record(rig.acknowledgments)
            }
        }

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))

        #expect(atReport.recorded == [
            SentAcknowledgment(acknowledged: true, message: "Bolus enacted successfully.", ackCode: "success")
        ])
        #expect(rig.harness.reporter.states == ["r1:pending", "r1:delivering"])
    }

    @Test func confirmWithoutUnitsAcknowledgesTheLoggedCarbs() async {
        let rig = RelayRig()
        await rig.ask("r1")

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: 0, carbs: 15))

        #expect(rig.harness.treatments.storedCarbs == [StoredCarbs(id: "r1", carbs: 15, fat: 10, protein: 8)])
        #expect(rig.harness.treatments.enacted.isEmpty)
        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: true, message: "Carbs logged successfully.", ackCode: "success")
        ])
    }

    @Test func failedConfirmAcknowledgesItsReason() async {
        let rig = RelayRig()
        rig.harness.treatments.enactResult = "Pump suspended"
        await rig.ask("r1")

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))

        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: false, message: "Pump suspended", ackCode: "failure")
        ])
    }

    @Test func lateConfirmAcknowledgesWhoLoggedIt() async {
        let rig = RelayRig()
        await rig.ask("r1")
        #expect(await rig.harness.coordinator.claim(id: "r1", on: .phone))

        // At once: the relay knows who claimed it without waiting for the main queue.
        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))

        #expect(rig.harness.treatments.storedCarbs.isEmpty && rig.harness.treatments.enacted.isEmpty)
        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: false, message: "Logged on your iPhone", ackCode: "failure")
        ])
    }

    @Test func confirmAfterTheIPhonesLogTookItAcknowledgesTheIPhone() async {
        let rig = RelayRig()
        await rig.ask("r1")
        // The iPhone's Log took the request, and its claim hasn't reached the coordinator yet.
        #expect(rig.harness.coordinator.take("r1", by: .phone))

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))

        #expect(rig.harness.treatments.storedCarbs.isEmpty && rig.harness.treatments.enacted.isEmpty)
        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: false, message: "Logged on your iPhone", ackCode: "failure")
        ])
    }

    @Test func lateConfirmAcknowledgesWhyTheRequestEnded() async {
        let rig = RelayRig()
        await rig.ask("r1")
        await rig.harness.coordinator.close(id: "r1", on: .phone, dismissed: false)
        await rig.ask("r2")
        await rig.harness.coordinator.withdraw(id: "r2", request: nil, via: .service)

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))
        await rig.relay.confirm(AIRequestWatchConfirm(id: "r2", units: d("1.2"), carbs: nil))

        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: false, message: "Declined on your iPhone", ackCode: "failure"),
            SentAcknowledgment(acknowledged: false, message: "Canceled by ChatGPT", ackCode: "failure")
        ])
        #expect(rig.harness.treatments.storedCarbs.isEmpty && rig.harness.treatments.enacted.isEmpty)
    }

    @Test func confirmOfAnUnknownRequestAcknowledgesAFailure() async {
        let rig = RelayRig()

        await rig.relay.confirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))

        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: false, message: "Expired", ackCode: "failure")
        ])
        #expect(rig.harness.treatments.storedCarbs.isEmpty && rig.harness.treatments.enacted.isEmpty)
    }

    /// The watch can send a confirm twice, live and queued. The first one's acknowledgement tells the wearer.
    @Test func repeatedConfirmIsNotAcknowledgedAgain() async {
        let rig = RelayRig()
        await rig.ask("r1")
        let confirm = AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)

        await rig.relay.confirm(confirm)
        await rig.relay.confirm(confirm)

        #expect(rig.harness.treatments.enacted == [d("1.2")])
        #expect(rig.acknowledgments == [
            SentAcknowledgment(acknowledged: true, message: "Bolus enacted successfully.", ackCode: "success")
        ])
    }

    @Test func closeMessageDeclines() async {
        let rig = RelayRig()
        await rig.ask("r1")
        await rig.ask("r2")
        // The second request replaced the first, so closing the first does nothing to the second.
        await rig.relay.close(AIRequestWatchClose(id: "r1", dismissed: false))
        #expect(rig.harness.coordinator.current.value?.request.id == "r2")

        await rig.relay.close(AIRequestWatchClose(id: "r2", dismissed: false))
        #expect(rig.harness.coordinator.current.value == nil)
        #expect(rig.harness.left.last == LeftEvent(id: "r2", left: .declined(.watch), source: "ChatGPT"))
        #expect(rig.harness.reporter.reports(for: "r2").last == .declined(on: .watch))

        await rig.ask("r3")
        await rig.relay.close(AIRequestWatchClose(id: "r3", dismissed: true))
        #expect(rig.harness.left.last == LeftEvent(id: "r3", left: .declined(.dismissed), source: "ChatGPT"))
        #expect(rig.harness.reporter.reports(for: "r3").last == .declined(on: .dismissed))
        // Closing declines; it doesn't log or give anything.
        #expect(rig.harness.treatments.storedCarbs.isEmpty && rig.harness.treatments.enacted.isEmpty)
    }

    @Test func leftIsSentToTheWatchExceptItsOwnClaim() async throws {
        let rig = RelayRig()
        await rig.ask("r1")
        #expect(await rig.harness.coordinator.claim(id: "r1", on: .phone))
        await rig.ask("r2")
        await rig.relay.confirm(AIRequestWatchConfirm(id: "r2", units: d("1.2"), carbs: nil))
        await rig.ask("r3")
        await rig.harness.coordinator.close(id: "r3", on: .phone, dismissed: false)
        await rig.ask("r4")
        await rig.harness.coordinator.withdraw(id: "r4", request: nil, via: .service)
        await rig.ask("r5")
        rig.harness.now = coordinatorTestStart + 5 * 60
        await rig.harness.coordinator.expireIfDue()

        // Each one is sent from the main queue, in the order the requests left.
        #expect(await eventuallyTrue { ((try? rig.ended().count) ?? 0) >= 4 })
        // The watch that claimed r2 knows that already; its acknowledgement tells the wearer.
        #expect(try rig.ended() == [
            AIRequestEnded(id: "r1", headline: "Logged on your iPhone", isSuccess: true),
            AIRequestEnded(id: "r3", headline: "Declined on your iPhone", isSuccess: false),
            AIRequestEnded(id: "r4", headline: "Canceled by ChatGPT", isSuccess: false),
            AIRequestEnded(id: "r5", headline: "Expired", isSuccess: false)
        ])
    }

    @Test func watchMessagesReachTheRelay() async throws {
        let rig = RelayRig()
        await rig.ask("r1")

        #expect(rig.link.receive([AIRequestIdentifiers.keyOpen: "r1"]))
        #expect(await eventuallyTrue {
            ((try? rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).count) ?? 0) == 1 })
        #expect(try rig.sent(AIRequestIdentifiers.keyDetails, as: AIRequestWatchDetails.self).first?.id == "r1")

        let confirm = AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)
        #expect(rig.link.receive([AIRequestIdentifiers.keyConfirm: try JSONEncoder().encode(confirm)]))
        #expect(await eventuallyTrue { rig.acknowledgments.count == 1 })
        #expect(rig.acknowledgments.first?.message == "Bolus enacted successfully.")

        await rig.ask("r2")
        let close = AIRequestWatchClose(id: "r2", dismissed: false)
        #expect(rig.link.receive([AIRequestIdentifiers.keyClose: try JSONEncoder().encode(close)]))
        #expect(await eventuallyTrue { rig.harness.left.contains(LeftEvent(id: "r2", left: .declined(.watch), source: "ChatGPT"))
        })
    }

    @Test func watchRequestMessagesAreHeldBeforeTheRuntime() throws {
        let holder = AIRequestMessageHolder()
        let confirm = AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)
        let close = AIRequestWatchClose(id: "r1", dismissed: false)
        let open: [String: Any] = [AIRequestIdentifiers.keyOpen: "r1"]
        let confirmed: [String: Any] = [AIRequestIdentifiers.keyConfirm: try JSONEncoder().encode(confirm)]
        let closed: [String: Any] = [AIRequestIdentifiers.keyClose: try JSONEncoder().encode(close)]

        #expect(holder.handle(open))
        #expect(holder.handle(confirmed))
        #expect(holder.handle(closed))

        var received: [[String: Any]] = []
        holder.install { received.append($0)
            return true }
        #expect(received.count == 3)
        #expect(received[0][AIRequestIdentifiers.keyOpen] as? String == "r1")
        #expect(received[1][AIRequestIdentifiers.keyConfirm] is Data)
        #expect(received[2][AIRequestIdentifiers.keyClose] is Data)
    }
}
