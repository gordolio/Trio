import Foundation
import Testing

@testable import Trio

@Suite("AI request coordinator – answers") struct AIRequestCoordinatorAnswerTests {
    @Test func signedWatchApprovalStoresCarbsAndDelivers() async throws {
        let h = makeCoordinator(dose: 1.2)
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1", carbs: 20), via: .service)
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        #expect(await h.coordinator.answer(.watch(a)) == .acted)
        #expect(h.treatments.stored.map(\.id) == ["r1"] && h.treatments.enacted == [1.2])
        #expect(h.treatments.checked == [1.2, 1.2]) // the safety checks ran on arrival and on the units it delivered
        #expect(h.reporter.states.last == "r1:delivering")
        #expect(h.reporter.reports.last?.report == .delivering(shown: h.prompt("r1").shown))
        #expect(h.coordinator.current.value == nil)
        #expect(h.backup.cancelled == ["r1"] && h.watch.withdrawn == ["r1"])
        #expect(!FileManager.default.fileExists(atPath: h.files.pending.path))
    }

    @Test func zeroDoseLogsCarbsOnly() async {
        let h = makeCoordinator(dose: 0)
        h.treatments.checkResult = "Over your max IOB" // a 0 U dose has no bolus to check
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(h.treatments.stored.map(\.id) == ["r1"])
        #expect(h.treatments.checked.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.reports.last?.report == .logged(shown: h.prompt("r1").shown))
    }

    @Test func secondAnswerIsIgnored() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(await h.coordinator.answer(.watch(a)) == .ignoredNotPending)
        #expect(await h.coordinator.answer(.phone(.decline, id: "r1")) == .ignoredNotPending)
        #expect(h.treatments.stored.map(\.id) == ["r1"] && h.treatments.enacted == [1.2])
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
        // A repeat of the request gets the same final report, and isn't asked or carried out again.
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.reporter.states == ["r1:pending", "r1:delivering", "r1:delivering"])
        #expect(h.reporter.reports[2].report == h.reporter.reports[1].report)
        #expect(h.treatments.stored.count == 1 && h.treatments.enacted.count == 1)
    }

    @Test func answerArrivingDuringAnApprovalIsIgnored() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        let during = TestBox<AIRequestCoordinator.AnswerOutcome?>(nil)
        h.treatments.whileCheckingBolus = { [coordinator = h.coordinator] in
            during.value = await coordinator.answer(.watch(a))
        }
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(during.value == .ignoredNotPending)
        #expect(h.treatments.stored.map(\.id) == ["r1"] && h.treatments.enacted == [1.2])
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
    }

    @Test func secondApprovalWaitsForTheFirstCarryOut() async {
        let h = makeCoordinator(dose: 1.2)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let second = TestBox<Task<AIRequestCoordinator.AnswerOutcome, Never>?>(nil)
        h.treatments.whileEnactingBolus = { [coordinator = h.coordinator, treatments = h.treatments, backup = h.backup] in
            // While the pump takes r1's bolus, r2 arrives and is approved.
            treatments.doseResult = AIRequestDose(units: 2.5, iobAsOf: coordinatorTestStart - 60)
            await coordinator.receive(meal(id: "r2"), via: .service)
            second.value = Task { await coordinator.answer(.phone(.approve, id: "r2")) }
            _ = await eventuallyTrue { backup.cancelled.contains("r2") }
            // r2 was checked once on arrival. Give its approval time to run ahead of r1's bolus, if it could.
            let checksOfR2 = { treatments.events.filter { $0 == "check 2.5" }.count }
            for _ in 0 ..< 20 where checksOfR2() < 2 {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(await second.value?.value == .acted)
        #expect(h.treatments.events == [
            "check 1.2", // r1 arrives
            "check 1.2", "store r1", "enact 1.2",
            "check 2.5", // r2 arrives
            "enacted 1.2",
            "check 2.5", "store r2", "enact 2.5", "enacted 2.5"
        ])
        #expect(h.reporter.states == ["r1:pending", "r2:pending", "r1:delivering", "r2:delivering"])
    }

    @Test func answerAfterExpiryIsIgnored() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        // Answered in time, but it arrives at `expiresAt`.
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now + 60, key: key)
        h.now = coordinatorTestStart + 5 * 60
        #expect(await h.coordinator.answer(.watch(a)) == .ignoredNotPending)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .ignoredNotPending)
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.states == ["r1:pending"])
    }

    @Test func answerForAnotherRequestIsIgnored() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        #expect(await h.coordinator.answer(.watch(a)) == .ignoredNotPending)
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value?.request.id == "r2")
        #expect(h.reporter.states == ["r1:pending", "r1:replaced", "r2:pending"])
    }

    @Test func phoneApprovalForAReplacedRequestIsIgnored() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .ignoredNotPending)
        #expect(h.treatments.checked == [1.2, 1.2]) // each checked on arrival only
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value?.request.id == "r2")
        #expect(h.reporter.states == ["r1:pending", "r1:replaced", "r2:pending"])
    }

    @Test func answerSignedSlightlyBeforeCreatedAtIsAccepted() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        // The watch's clock is behind the service's.
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now - 30, key: key)
        #expect(await h.coordinator.answer(.watch(a)) == .acted)
        #expect(h.treatments.stored.map(\.id) == ["r1"] && h.treatments.enacted == [1.2])
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
    }

    @Test func answerSignedOutsideTheRequestsWindowIsIgnored() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let early = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now - 120, key: key)
        // Signed after `expiresAt` by a watch clock that's ahead, while the phone still has it pending.
        let late = AIRequestSigner.sign(
            prompt: h.prompt("r1"),
            decision: .approve,
            declinedBy: nil,
            at: coordinatorTestStart + 5 * 60 + 1,
            key: key
        )
        #expect(await h.coordinator.answer(.watch(early)) == .ignoredNotPending)
        #expect(await h.coordinator.answer(.watch(late)) == .ignoredNotPending)
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.reporter.states == ["r1:pending"])
    }

    @Test func answerInTheSecondTheRequestWasCreatedIsAccepted() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        let created = coordinatorTestStart + 0.5
        let request = AIMealRequest(
            id: "r1",
            source: "ChatGPT",
            description: "slice of pizza",
            carbs: 20,
            fat: 10,
            protein: 8,
            createdAt: created,
            expiresAt: created + 5 * 60
        )
        await h.coordinator.receive(request, via: .service)
        // An answer 0.2 s later is signed with the whole second, which is before `createdAt`.
        let a = AIRequestSigner.sign(
            prompt: h.prompt("r1"),
            decision: .approve,
            declinedBy: nil,
            at: coordinatorTestStart,
            key: key
        )
        #expect(await h.coordinator.answer(.watch(a)) == .acted)
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
    }

    @Test func badSignatureIsRejectedAndRequestStaysPending() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let forged = AIRequestSigner.sign(
            prompt: h.prompt("r1"),
            decision: .approve,
            declinedBy: nil,
            at: h.now,
            key: Data(repeating: 7, count: 32)
        )
        #expect(await h.coordinator.answer(.watch(forged)) == .rejectedSignature)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.states == ["r1:pending"])
        // Still pending, so the wearer's own answer is carried out.
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        #expect(await h.coordinator.answer(.watch(a)) == .acted)
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
    }

    @Test func answerWithoutAKeyIsRejected() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let a = AIRequestSigner.sign(
            prompt: h.prompt("r1"),
            decision: .approve,
            declinedBy: nil,
            at: h.now,
            key: Data(repeating: 7, count: 32)
        )
        #expect(await h.coordinator.answer(.watch(a)) == .rejectedSignature)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func answerOfAnotherVersionIsRejected() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: h.now, key: key)
        // The MAC doesn't cover `v`, so it still checks out.
        let v2 = AIRequestAnswer(
            v: 2,
            requestId: a.requestId,
            decision: a.decision,
            declinedBy: a.declinedBy,
            shown: a.shown,
            answeredAt: a.answeredAt,
            mac: a.mac
        )
        #expect(AIRequestSigner.isValid(v2, key: key))
        #expect(await h.coordinator.answer(.watch(v2)) == .rejectedSignature)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func mismatchedValuesAreRejected() async throws {
        let h = makeCoordinator(dose: 1.2)
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.prompt("r1").shown.units == "1.20")
        let a = AIRequestSigner.sign(
            prompt: h.prompt("r1").showing(units: "3.00"),
            decision: .approve,
            declinedBy: nil,
            at: h.now,
            key: key
        )
        #expect(await h.coordinator.answer(.watch(a)) == .rejectedValues)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.states == ["r1:pending"])
    }

    @Test func failedSafetyCheckStoresNothing() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.treatments.checkResult = "Over your max IOB" // allowed on arrival, refused at approval
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(h.reporter.reports.last?.report == .failed(reason: "Over your max IOB", carbsLogged: false))
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value == nil)
    }

    @Test func limitsAreCheckedAgainOnApproval() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1", carbs: 20), via: .service)
        h.treatments.limits = AIRequestLimits(maxCarbs: 10, maxFat: 250, maxProtein: 250, maxBolus: 10)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(h.reporter.reports.last?.report == .failed(reason: "Over your max carbs (10 g)", carbsLogged: false))
        #expect(h.treatments.checked == [1.2]) // on arrival, not at approval
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func unsavedCarbsDeliverNothing() async {
        let h = makeCoordinator()
        h.treatments.storeError = TestStoreError.diskFull
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(h.reporter.reports.last?.report == .failed(reason: "Couldn't save the carbs", carbsLogged: false))
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func pumpFailureKeepsCarbsAndSaysSo() async {
        let h = makeCoordinator()
        h.treatments.enactResult = "Pump not responding"
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .acted)
        #expect(h.treatments.stored.map(\.id) == ["r1"])
        #expect(h.reporter.reports.last?.report == .failed(reason: "Pump not responding", carbsLogged: true))
        #expect(h.treatments.enacted == [1.2]) // tried once, not again
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .ignoredNotPending)
        #expect(h.treatments.enacted == [1.2] && h.reporter.states == ["r1:pending", "r1:failed"])
    }

    @Test func dismissedDeclineIsReportedAsDismissed() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .decline, declinedBy: .dismissed, at: h.now, key: key)
        #expect(await h.coordinator.answer(.watch(a)) == .acted)
        #expect(h.reporter.reports.last?.report == .declined(on: .dismissed))
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value == nil && h.backup.cancelled == ["r1"] && h.watch.withdrawn == ["r1"])
    }

    @Test func watchDeclineIsReportedAsTheWatch() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let button = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .decline, declinedBy: .button, at: h.now, key: key)
        #expect(await h.coordinator.answer(.watch(button)) == .acted)
        // A decline without `declinedBy` came from a button, not a dismissal.
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        let unsaid = AIRequestSigner.sign(prompt: h.prompt("r2"), decision: .decline, declinedBy: nil, at: h.now, key: key)
        #expect(unsaid.declinedBy == nil)
        #expect(await h.coordinator.answer(.watch(unsaid)) == .acted)
        #expect(h.reporter.reports.map(\.report).filter { $0.state == .declined } == [
            .declined(on: .watch),
            .declined(on: .watch)
        ])
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func phoneDecline() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.answer(.phone(.decline, id: "r1")) == .acted)
        #expect(h.reporter.reports.last?.report == .declined(on: .phone))
        #expect(h.reporter.states == ["r1:pending", "r1:declined"])
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func answerWithNothingPendingIsIgnored() async {
        let h = makeCoordinator()
        #expect(await h.coordinator.answer(.phone(.approve, id: "r1")) == .ignoredNotPending)
        #expect(h.reporter.reports.isEmpty && h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func answerAfterRelaunchActsOnTheSavedRequest() async throws {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files, now: coordinatorTestStart + 60)
        let key = try #require(relaunched.keys.rotate())
        let a = AIRequestSigner.sign(prompt: h.prompt("r1"), decision: .approve, declinedBy: nil, at: relaunched.now, key: key)
        #expect(await relaunched.coordinator.answer(.watch(a)) == .acted)
        #expect(relaunched.treatments.stored.map(\.id) == ["r1"] && relaunched.treatments.enacted == [1.2])
        #expect(relaunched.reporter.states == ["r1:delivering"])
    }
}

private enum TestStoreError: LocalizedError {
    case diskFull

    var errorDescription: String? { "Couldn't save the carbs" }
}

private extension AIRequestPrompt {
    /// The same prompt, showing other units.
    func showing(units: String) -> AIRequestPrompt {
        AIRequestPrompt(
            id: id,
            source: source,
            description: description,
            shown: AIRequestShown(carbs: shown.carbs, fat: shown.fat, protein: shown.protein, units: units),
            title: title,
            body: body,
            expiresAt: expiresAt,
            approvalStyle: approvalStyle,
            answerRoute: answerRoute,
            answerToken: answerToken,
            answerURL: answerURL
        )
    }
}
