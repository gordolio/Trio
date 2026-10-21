import Combine
import Foundation
import Testing

@testable import Trio

@Suite("AI request outcomes") struct AIRequestOutcomeTests {
    @Test func approvedRequestSendsOneOutcome() async {
        let h = makeCoordinator()
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r1", carbs: 20), via: .service)
        #expect(outcomes.all.isEmpty) // pending isn't final
        _ = await h.coordinator.answer(.phone(.approve, id: "r1"))
        let shown = h.prompt("r1").shown
        #expect(outcomes.all == [AIRequestOutcome(
            id: "r1",
            title: "ChatGPT: slice of pizza",
            source: "ChatGPT",
            shown: shown,
            report: .delivering(shown: shown),
            askedOn: .watch,
            approvedOn: .phone,
            declinedOn: nil,
            bolusUnconfirmed: false
        )])
    }

    @Test func watchApprovalIsApprovedOnTheWatch() async throws {
        let h = makeCoordinator(watchAvailable: true)
        let key = try #require(h.keys.rotate())
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let answer = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        #expect(await h.coordinator.answer(.watch(answer)) == .acted)
        #expect(outcomes.all.map(\.approvedOn) == [.watch])
        #expect(outcomes.all.map(\.askedOn) == [.watch])
    }

    @Test func requestAskedOnThePhoneSaysSo() async {
        let h = makeCoordinator(watchAvailable: false)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        _ = await h.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(outcomes.all.map(\.askedOn) == [.phone])
    }

    @Test(
        "A test request is shown on the watch by Trio itself, so its outcome says so even when it was asked on the iPhone"
    ) func testRequestOutcomeSaysItWasDeliveredToTheWatch() async {
        // No watch push token: the request is asked on the iPhone, but Trio still shows it on the watch.
        let h = makeCoordinator(watchAvailable: false)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        var test = meal(id: "r1")
        test.testKind = .dryRun
        await h.coordinator.receive(test, via: .local)
        #expect(h.watch.delivered.map(\.id) == ["r1"])
        _ = await h.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(outcomes.all.map(\.askedOn) == [.phone])
        #expect(outcomes.all.map(\.deliveredToWatch) == [true])
        #expect(outcomes.all.map(\.reachesWatch) == [true])

        // Replaced, expired or withdrawn, it was still shown there.
        await h.coordinator.receive(meal(id: "r2"), via: .local)
        await h.coordinator.receive(meal(id: "r3"), via: .local)
        #expect(outcomes.all.map(\.id) == ["r1", "r2"])
        #expect(outcomes.all.map(\.deliveredToWatch) == [true, true])

        // A test request refused on arrival was never shown anywhere.
        h.treatments.checkResult = "Over your max IOB"
        await h.coordinator.receive(meal(id: "r4"), via: .local)
        #expect(outcomes.all.last?.id == "r4")
        #expect(outcomes.all.last?.deliveredToWatch == false)
        #expect(outcomes.all.last?.reachesWatch == false)
    }

    @Test(
        "An assistant's request reaches the watch by the service's push, so only being asked there sends its result"
    ) func serviceRequestOutcomeIsNotDeliveredByTrio() async {
        let onPhone = makeCoordinator(watchAvailable: false)
        let phoneOutcomes = OutcomeRecorder(onPhone.coordinator.outcomes)
        await onPhone.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(onPhone.watch.delivered.isEmpty)
        _ = await onPhone.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(phoneOutcomes.all.map(\.deliveredToWatch) == [false])
        #expect(phoneOutcomes.all.map(\.reachesWatch) == [false])

        let onWatch = makeCoordinator(watchAvailable: true)
        let watchOutcomes = OutcomeRecorder(onWatch.coordinator.outcomes)
        await onWatch.coordinator.receive(meal(id: "r1"), via: .service)
        _ = await onWatch.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(watchOutcomes.all.map(\.deliveredToWatch) == [false])
        #expect(watchOutcomes.all.map(\.reachesWatch) == [true])
    }

    @Test func repeatedIDSendsNoSecondOutcome() async {
        let h = makeCoordinator()
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r1"), via: .service) // a repeat while pending
        #expect(outcomes.all.isEmpty)
        _ = await h.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(outcomes.all.count == 1)

        await h.coordinator.receive(meal(id: "r1"), via: .service) // a repeat after it finished
        await h.coordinator.withdraw(id: "r1", request: nil, via: .service)
        await h.coordinator.withdraw(id: "r1", request: meal(id: "r1"), via: .service)
        await h.coordinator.expireIfDue()
        #expect(outcomes.all.count == 1)
        // The assistant still hears the pending report again while pending, and the first final report after.
        #expect(
            h.reporter
                .states == ["r1:pending", "r1:pending", "r1:delivering", "r1:delivering", "r1:delivering", "r1:delivering"]
        )
    }

    @Test func refusedOnArrivalSendsAnOutcomeWithoutApproval() async {
        let h = makeCoordinator()
        h.treatments.checkResult = "Over your max IOB"
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(outcomes.all == [AIRequestOutcome(
            id: "r1",
            title: "ChatGPT: slice of pizza",
            source: "ChatGPT",
            shown: nil,
            report: .failed(reason: "Over your max IOB", carbsLogged: false),
            askedOn: nil,
            approvedOn: nil,
            declinedOn: nil
        )])
        #expect(outcomes.all.first?.approvedOn == nil)
    }

    @Test func requestRefusedForItsAmountsAndTheSwitchSendsOutcomes() async {
        let limited = makeCoordinator(limits: AIRequestLimits(maxCarbs: 10, maxFat: 250, maxProtein: 250))
        let limitedOutcomes = OutcomeRecorder(limited.coordinator.outcomes)
        await limited.coordinator.receive(meal(id: "a", carbs: 20), via: .service)
        #expect(limitedOutcomes.all.map(\.report) == [.failed(reason: "Over your max carbs (10 g)", carbsLogged: false)])

        let off = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: false))
        let offOutcomes = OutcomeRecorder(off.coordinator.outcomes)
        await off.coordinator.receive(meal(id: "b"), via: .service)
        #expect(offOutcomes.all.map(\.report) == [.failed(reason: "Meal requests are off in Trio", carbsLogged: false)])
        #expect(offOutcomes.all.map(\.title) == ["ChatGPT: slice of pizza"])
    }

    @Test func requestThatArrivesExpiredSendsAnOutcome() async {
        let h = makeCoordinator(now: coordinatorTestStart + 6 * 60)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(outcomes.all.map(\.report) == [.expired])
        #expect(outcomes.all.map(\.askedOn) == [nil])
    }

    @Test func failureAfterApprovalSaysWhoApproved() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.treatments.enactResult = "Pump suspended"
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        _ = await h.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(outcomes.all.map(\.report) == [.failed(reason: "Pump suspended", carbsLogged: true)])
        #expect(outcomes.all.map(\.approvedOn) == [.phone])
        #expect(outcomes.all.map(\.bolusUnconfirmed) == [false])
        #expect(outcomes.all.first?.shown == h.prompt("r1").shown)
    }

    @Test func refusalAtApprovalSaysWhoApproved() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.treatments.carbsLoggedResult = true
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        _ = await h.coordinator.answer(.phone(.approve, id: "r1"))
        #expect(
            outcomes.all
                .map(\.report) == [.failed(reason: "Carbs were logged after this request arrived", carbsLogged: false)]
        )
        #expect(outcomes.all.map(\.approvedOn) == [.phone])
    }

    @Test func zeroDoseAndDryRunSendTheirOwnOutcomes() async {
        let zero = makeCoordinator(dose: 0)
        let zeroOutcomes = OutcomeRecorder(zero.coordinator.outcomes)
        await zero.coordinator.receive(meal(id: "a"), via: .service)
        _ = await zero.coordinator.answer(.phone(.approve, id: "a"))
        #expect(zeroOutcomes.all.map(\.report) == [.logged(shown: zero.prompt("a").shown)])

        let dry = makeCoordinator()
        let dryOutcomes = OutcomeRecorder(dry.coordinator.outcomes)
        var test = meal(id: "b")
        test.testKind = .dryRun
        await dry.coordinator.receive(test, via: .local)
        _ = await dry.coordinator.answer(.phone(.approve, id: "b"))
        #expect(dryOutcomes.all.map(\.report) == [.dryRun(shown: dry.prompt("b").shown)])
        #expect(dryOutcomes.all.map(\.approvedOn) == [.phone])
    }

    @Test func declineOnThePhoneSendsAnOutcomeWithWhereItWasDeclined() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        #expect(await h.coordinator.answer(.phone(.decline, id: "r1")) == .acted)
        expectDeclined(outcomes.all, on: .phone)
    }

    @Test(arguments: [
        (AIRequestDeclinedBy.button, AIRequestDeclinedOn.watch),
        (.dismissed, .dismissed)
    ]) func declineOnTheWatchSendsAnOutcomeWithWhereItWasDeclined(
        declinedBy: AIRequestDeclinedBy,
        declinedOn: AIRequestDeclinedOn
    ) async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let answer = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .decline, declinedBy: declinedBy, at: h.now, key: key)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        #expect(await h.coordinator.answer(.watch(answer)) == .acted)
        expectDeclined(outcomes.all, on: declinedOn)
    }

    @Test func replacedRequestSendsAnOutcomeWithItsOwnTitle() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(outcomes.all.map(\.id) == ["r1"])
        #expect(outcomes.all.map(\.report) == [.replaced])
        #expect(outcomes.all.map(\.askedOn) == [.watch])
        #expect(outcomes.all.map(\.shown) == [h.prompt("r1").shown])
    }

    @Test func expiredWithdrawnAndUnseenWithdrawnRequestsSendOutcomes() async {
        let h = makeCoordinator()
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)

        await h.coordinator.receive(meal(id: "a"), via: .service)
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()

        h.now = coordinatorTestStart
        await h.coordinator.receive(meal(id: "b"), via: .service)
        await h.coordinator.withdraw(id: "b", request: nil, via: .service)

        // The inbox lists a request Trio never saw as withdrawn.
        await h.coordinator.withdraw(id: "c", request: meal(id: "c"), via: .service)

        #expect(outcomes.all.map(\.id) == ["a", "b", "c"])
        #expect(outcomes.all.map(\.report) == [.expired, .withdrawn, .withdrawn])
        #expect(outcomes.all.map(\.askedOn) == [.watch, .watch, nil])
        #expect(outcomes.all.map(\.title) == Array(repeating: "ChatGPT: slice of pizza", count: 3))
        #expect(outcomes.all.map(\.source) == Array(repeating: "ChatGPT", count: 3))
    }

    @Test(arguments: [
        (AIRequestCarryOutMarker.Stage.checking, false, false),
        (.storingCarbs, true, false),
        (.enacting, true, true)
    ]) func markerFailureSendsAnOutcome(
        stage: AIRequestCarryOutMarker.Stage,
        carbsLogged: Bool,
        bolusUnconfirmed: Bool
    ) async throws {
        let files = CoordinatorFiles.temporary()
        _ = try AIRequestSeenStore(fileURL: files.seen, now: { coordinatorTestStart }).observe("a")
        let shown = AIRequestShown(carbs: "20.00", fat: "10.00", protein: "8.00", units: "1.20")
        AIRequestCarryOutMarker(
            id: "a",
            channel: .service,
            title: "ChatGPT: slice of pizza",
            source: "ChatGPT",
            shown: shown,
            askedOn: .watch,
            approvedOn: .watch,
            stage: stage
        ).save(to: files.pending.deletingLastPathComponent().appendingPathComponent("carrying-out.json"))
        let h = makeCoordinator(files: files)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.start()
        let reason = stage == .enacting
            ? "Trio stopped while starting the bolus. It may have been given"
            : "Trio stopped before it finished"
        #expect(outcomes.all == [AIRequestOutcome(
            id: "a",
            title: "ChatGPT: slice of pizza",
            source: "ChatGPT",
            shown: shown,
            report: .failed(reason: reason, carbsLogged: carbsLogged),
            askedOn: .watch,
            approvedOn: .watch,
            declinedOn: nil,
            bolusUnconfirmed: bolusUnconfirmed
        )])

        // Reported once: a second start and a repeat of the request send nothing more.
        await h.coordinator.start()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(outcomes.all.count == 1)
    }

    @Test func markerOfATestRequestSaysItWasDeliveredToTheWatch() async throws {
        let files = CoordinatorFiles.temporary()
        _ = try AIRequestSeenStore(fileURL: files.seen, now: { coordinatorTestStart }).observe("a")
        AIRequestCarryOutMarker(
            id: "a",
            channel: .local,
            title: "Trio test: 10 g carbs",
            source: "Trio test",
            shown: AIRequestShown(carbs: "10.00", fat: "0.00", protein: "0.00", units: "0.50"),
            askedOn: .phone,
            approvedOn: .phone,
            stage: .checking
        ).save(to: files.pending.deletingLastPathComponent().appendingPathComponent("carrying-out.json"))
        let h = makeCoordinator(files: files)
        let outcomes = OutcomeRecorder(h.coordinator.outcomes)
        await h.coordinator.start()
        #expect(outcomes.all.map(\.deliveredToWatch) == [true])
        #expect(outcomes.all.map(\.reachesWatch) == [true])
    }

    @Test func markerOfAnAlreadyReportedRequestSendsNoOutcome() async {
        let files = CoordinatorFiles.temporary()
        let first = makeCoordinator(files: files)
        await first.coordinator.receive(meal(id: "a"), via: .service)
        _ = await first.coordinator.answer(.phone(.approve, id: "a"))
        AIRequestCarryOutMarker(
            id: "a",
            channel: .service,
            title: "ChatGPT: slice of pizza",
            source: "ChatGPT",
            shown: first.prompt("a").shown,
            askedOn: .watch,
            approvedOn: .watch,
            stage: .enacting
        ).save(to: files.pending.deletingLastPathComponent().appendingPathComponent("carrying-out.json"))
        let relaunched = makeCoordinator(files: files)
        let outcomes = OutcomeRecorder(relaunched.coordinator.outcomes)
        await relaunched.coordinator.start()
        #expect(outcomes.all.isEmpty)
    }
}

/// The one outcome of a declined request, with where it was declined and no approval.
private func expectDeclined(_ outcomes: [AIRequestOutcome], on declinedOn: AIRequestDeclinedOn) {
    #expect(outcomes.map(\.report) == [.declined(on: declinedOn)])
    #expect(outcomes.map(\.declinedOn) == [declinedOn])
    #expect(outcomes.map(\.approvedOn) == [nil])
    #expect(outcomes.map(\.title) == ["ChatGPT: slice of pizza"])
}

/// What a coordinator's `outcomes` sent, in order.
private final class OutcomeRecorder {
    private let lock = NSLock()
    private var received: [AIRequestOutcome] = []
    private var subscription: AnyCancellable?

    init(_ outcomes: PassthroughSubject<AIRequestOutcome, Never>) {
        subscription = outcomes.sink { [weak self] outcome in
            guard let self else { return }
            lock.withLock { self.received.append(outcome) }
        }
    }

    var all: [AIRequestOutcome] { lock.withLock { received } }
}
