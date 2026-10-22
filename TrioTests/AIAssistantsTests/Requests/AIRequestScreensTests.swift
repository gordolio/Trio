import Foundation
import Testing

@testable import Trio

/// The request opened on Trio's own screens: which device has it open, which one claims it, and how it ends.
@Suite("AI request coordinator – screens") struct AIRequestScreensTests {
    /// When `meal(id:)`'s requests expire.
    private let expiresAt = coordinatorTestStart + 5 * 60

    @Test func openReturnsLiveDetails() async {
        let h = makeCoordinator(dose: 1.2)
        await h.coordinator.receive(meal(id: "r1", carbs: d("82.5"), fat: 10, protein: 5), via: .service)
        h.treatments.doseResult = AIRequestDose(units: d("2.157"))
        let details = await h.coordinator.open(id: "r1", on: .watch)
        #expect(details == AIRequestWatchDetails(
            id: "r1",
            carbs: d("82.5"),
            fat: 10,
            protein: 5,
            units: d("2.15"),
            expiresAt: expiresAt
        ))
        // The watch opening it puts the iPhone's backup off by a minute, once.
        #expect(h.backup.scheduled.map(\.delay) == [15, 60])
        _ = await h.coordinator.open(id: "r1", on: .watch)
        #expect(h.backup.scheduled.map(\.delay) == [15, 60])
        #expect(h.coordinator.current.value?.request.id == "r1")
    }

    @Test func openUnknownIDReturnsNil() async {
        let h = makeCoordinator()
        #expect(await h.coordinator.open(id: "r1", on: .watch) == nil)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r2", on: .watch) == nil)
        #expect(await h.coordinator.open(id: "r2", on: .phone) == nil)
        #expect(h.backup.scheduled.map(\.delay) == [15])
    }

    @Test func openScreenHoldsExpiry() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .phone) != nil)
        h.now = expiresAt + 1
        await h.coordinator.expireIfDue()
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left.isEmpty)
    }

    @Test func openScreenHoldsExpiryAtMostTenMinutes() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .phone) != nil)
        h.now = expiresAt + 10 * 60 - 1
        await h.coordinator.expireIfDue()
        #expect(h.coordinator.current.value?.request.id == "r1")
        h.now = expiresAt + 10 * 60
        await h.coordinator.expireIfDue()
        #expect(h.coordinator.current.value == nil)
        #expect(h.reporter.reports.last?.report == .expired)
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
        #expect(h.left == [LeftEvent(id: "r1", left: .expired, source: "ChatGPT")])
    }

    @Test func relaunchDropsTheHold() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .phone) != nil)
        let relaunched = makeCoordinator(files: h.files, now: expiresAt + 1)
        await relaunched.coordinator.start()
        #expect(relaunched.reporter.states == ["r1:expired"])
        #expect(relaunched.coordinator.current.value == nil)
        #expect(relaunched.left == [LeftEvent(id: "r1", left: .expired, source: "ChatGPT")])
    }

    @Test func openAfterExpiryDoesNotOpenAndExpires() async {
        // The watch's flow ended without answering ("Open the request again."), so its hold stayed. Reopening the request
        // after its five minutes doesn't open it: its hold goes, and with nothing else holding it, it expires.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .watch) != nil)
        h.now = expiresAt + 60
        #expect(await h.coordinator.open(id: "r1", on: .watch) == nil)
        #expect(h.coordinator.current.value == nil)
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
        #expect(h.left == [LeftEvent(id: "r1", left: .expired, source: "ChatGPT")])

        // The same for the iPhone, whose sheet went without answering.
        h.now = coordinatorTestStart
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(await h.coordinator.open(id: "r2", on: .phone) != nil)
        h.now = expiresAt + 60
        #expect(await h.coordinator.open(id: "r2", on: .phone) == nil)
        #expect(h.coordinator.current.value == nil)
        #expect(h.reporter.reports(for: "r2").last == .expired)
    }

    @Test func openAfterExpiryWhileTheOtherSideHoldsDoesNotOpen() async {
        // The watch has the request's Confirm screen up past its five minutes. The iPhone's backup is tapped: it doesn't
        // open, and the request stays held for the watch.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .watch) != nil)
        h.now = expiresAt + 60
        #expect(await h.coordinator.open(id: "r1", on: .phone) == nil)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left.isEmpty)

        // The watch's confirm still goes through.
        let report = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))
        #expect(report == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: d("1.2"))))
    }

    @Test func openingAfterExpiryExpiresInstead() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = expiresAt
        #expect(await h.coordinator.open(id: "r1", on: .watch) == nil)
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
    }

    @Test func closingAnUnclaimedRequestDeclines() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .phone) != nil)
        await h.coordinator.close(id: "r1", on: .phone, dismissed: false)
        #expect(h.reporter.reports.last?.report == .declined(on: .phone))
        #expect(h.coordinator.current.value == nil)

        await h.coordinator.receive(meal(id: "r2"), via: .service)
        await h.coordinator.close(id: "r2", on: .watch, dismissed: true)
        #expect(h.reporter.reports.last?.report == .declined(on: .dismissed))

        await h.coordinator.receive(meal(id: "r3"), via: .service)
        await h.coordinator.close(id: "r3", on: .watch, dismissed: false)
        #expect(h.reporter.reports.last?.report == .declined(on: .watch))

        #expect(h.left == [
            LeftEvent(id: "r1", left: .declined(.phone), source: "ChatGPT"),
            LeftEvent(id: "r2", left: .declined(.dismissed), source: "ChatGPT"),
            LeftEvent(id: "r3", left: .declined(.watch), source: "ChatGPT")
        ])
    }

    @Test func closingOnThePhoneIgnoresDismissed() async {
        // Only the watch's notification can be swiped away: the phone's close is always a decline on the iPhone.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.close(id: "r1", on: .phone, dismissed: true)
        #expect(h.reporter.reports.last?.report == .declined(on: .phone))
        #expect(h.left == [LeftEvent(id: "r1", left: .declined(.phone), source: "ChatGPT")])
    }

    @Test func swipingTheWatchNotificationAwayLeavesARequestOpenOnTheIPhone() async {
        // The wearer is finishing it on the iPhone's Treatments sheet, and clears the watch's notification.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.open(id: "r1", on: .phone) != nil)
        await h.coordinator.close(id: "r1", on: .watch, dismissed: true)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left.isEmpty)
        #expect(await h.coordinator.claim(id: "r1", on: .phone))
    }

    @Test func closingARequestThatIsntPendingDoesNothing() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.claim(id: "r1", on: .phone))
        await h.coordinator.close(id: "r1", on: .watch, dismissed: false)
        await h.coordinator.close(id: "r9", on: .phone, dismissed: false)
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.phone), source: "ChatGPT")])
    }

    @Test func secondClaimIsRefused() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.claim(id: "r1", on: .phone))
        #expect(await h.coordinator.claim(id: "r1", on: .phone) == false)
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.phone), source: "ChatGPT")])
        #expect(h.coordinator.current.value == nil)
        #expect(h.backup.cancelled == ["r1"])
        // The phone reports what it did; nothing is reported yet.
        #expect(h.reporter.states == ["r1:pending"])
    }

    @Test func claimRefusesTheWatch() async {
        // The watch carries a request out with `carryOutWatchConfirm`, which reports it. A claim for the watch would
        // take the request out of pending and leave a claim nothing reports.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.claim(id: "r1", on: .watch) == false)
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.left.isEmpty)
        #expect(h.backup.cancelled.isEmpty)
        // The request is still there for the watch's confirmation.
        let report = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))
        #expect(report == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: d("1.2"))))
    }

    @Test func watchConfirmAfterPhoneClaimLogsNothing() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.claim(id: "r1", on: .phone))
        let report = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))
        #expect(report == nil)
        #expect(h.treatments.storedCarbs.isEmpty)
        #expect(h.treatments.enacted.isEmpty)
        #expect(h.reporter.states == ["r1:pending"])
    }

    @Test func watchConfirmAfterTheIPhonesLogTookItLogsNothing() async {
        // The iPhone's Log took the request, and the watch's confirm reaches the coordinator before the iPhone's claim.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.coordinator.take("r1", by: .phone))
        let report = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))
        #expect(report == nil)
        #expect(h.treatments.storedCarbs.isEmpty)
        #expect(h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value?.request.id == "r1")

        // The iPhone's claim gets the request when it arrives.
        #expect(await h.coordinator.claim(id: "r1", on: .phone))
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.phone), source: "ChatGPT")])
    }

    @Test func iPhonesLogAfterTheWatchTookItIsRefused() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)) != nil)
        #expect(h.coordinator.taker(of: "r1") == .watch)
        #expect(!h.coordinator.take("r1", by: .phone))
        #expect(await h.coordinator.claim(id: "r1", on: .phone) == false)
    }

    @Test func watchConfirmLogsTheRequestsExactGrams() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1", carbs: d("82.5"), fat: 10, protein: 5), via: .service)
        let exact = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("2.15"), carbs: nil))
        #expect(exact == .delivering(shown: AIRequestShown(carbs: d("82.5"), fat: 10, protein: 5, units: d("2.15"))))

        await h.coordinator.receive(meal(id: "r2", carbs: d("82.5"), fat: 10, protein: 5), via: .service)
        let changed = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r2", units: 2, carbs: 80))
        #expect(changed == .delivering(shown: AIRequestShown(carbs: 80, fat: 10, protein: 5, units: 2)))

        #expect(h.treatments.storedCarbs == [
            StoredCarbs(id: "r1", carbs: d("82.5"), fat: 10, protein: 5),
            StoredCarbs(id: "r2", carbs: 80, fat: 10, protein: 5)
        ])
        #expect(h.treatments.enacted == [d("2.15"), 2])
        #expect(h.reporter.reports(for: "r1").last == exact)
        #expect(h.reporter.reports(for: "r2").last == changed)
        #expect(h.left == [
            LeftEvent(id: "r1", left: .claimed(.watch), source: "ChatGPT"),
            LeftEvent(id: "r2", left: .claimed(.watch), source: "ChatGPT")
        ])
    }

    @Test func watchConfirmLogsCarbsOnlyWhenEntriesAreOff() async {
        // "Enable Fat and Protein Entries" is off, as it is by default: the request's fat and protein aren't logged, so
        // Trio doesn't turn them into carb equivalents to dose for, and the report says so.
        let h = makeCoordinator()
        h.treatments.logsFatAndProtein = false
        await h.coordinator.receive(meal(id: "r1", carbs: d("82.5"), fat: 10, protein: 5), via: .service)
        let exact = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("2.15"), carbs: nil))
        #expect(exact == .delivering(shown: AIRequestShown(carbs: d("82.5"), fat: 0, protein: 0, units: d("2.15"))))

        await h.coordinator.receive(meal(id: "r2", carbs: 40, fat: 10, protein: 5), via: .service)
        let carbsOnly = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r2", units: 0, carbs: 30))
        #expect(carbsOnly == .logged(shown: AIRequestShown(carbs: 30, fat: 0, protein: 0, units: 0)))

        #expect(h.treatments.storedCarbs == [
            StoredCarbs(id: "r1", carbs: d("82.5"), fat: 0, protein: 0),
            StoredCarbs(id: "r2", carbs: 30, fat: 0, protein: 0)
        ])
        #expect(h.reporter.reports(for: "r1").last == exact)
        #expect(h.reporter.reports(for: "r2").last == carbsOnly)
    }

    @Test func confirmAfterExpiryLogsNothing() async {
        // Confirmed in time on the watch, but it reaches the iPhone at `expiresAt`, with no screen holding the request.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = expiresAt
        #expect(await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)) == nil)
        #expect(h.treatments.storedCarbs.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
        #expect(h.reporter.reports(for: "r1").last == .expired)
        #expect(h.left == [LeftEvent(id: "r1", left: .expired, source: "ChatGPT")])
    }

    @Test func phoneClaimAfterExpiryLogsNothing() async {
        // The iPhone's Log reaches the coordinator at `expiresAt`, with no screen holding the request.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = expiresAt
        #expect(await h.coordinator.claim(id: "r1", on: .phone) == false)
        // A result for it changes nothing: the iPhone never claimed it.
        await h.coordinator.reportPhoneResult(
            id: "r1",
            AIRequestPhoneResult(carbs: 20, fat: 10, protein: 8, units: d("1.2"), bolus: .started)
        )
        #expect(h.treatments.storedCarbs.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
        #expect(h.reporter.reports(for: "r1").last == .expired)
        #expect(h.left == [LeftEvent(id: "r1", left: .expired, source: "ChatGPT")])
    }

    @Test func watchConfirmCapsAtMaxBolus() async {
        let h = makeCoordinator(limits: AIRequestLimits(maxCarbs: 250, maxFat: 250, maxProtein: 250, maxBolus: 10))
        await h.coordinator.receive(meal(id: "r1", carbs: 20, fat: 10, protein: 8), via: .service)
        let report = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: 12, carbs: nil))
        #expect(h.treatments.enacted == [10])
        #expect(report == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 10)))
    }

    @Test func watchConfirmReportsWhatWasDone() async {
        let h = makeCoordinator()
        // No bolus: the carbs are logged.
        await h.coordinator.receive(meal(id: "r1", carbs: 20, fat: 10, protein: 8), via: .service)
        let logged = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: 0, carbs: nil))
        #expect(logged == .logged(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 0)))
        #expect(h.treatments.enacted.isEmpty)

        // The pump refuses: the carbs stay logged.
        h.treatments.enactResult = "Pump suspended"
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        let failed = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r2", units: 1, carbs: nil))
        #expect(failed == .failed(reason: "Pump suspended", carbsLogged: true))

        // The carbs don't save: nothing is given.
        h.treatments.storeError = AIRequestCarbsNotSavedError(underlying: nil)
        await h.coordinator.receive(meal(id: "r3"), via: .service)
        let unsaved = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r3", units: 1, carbs: nil))
        #expect(unsaved == .failed(reason: "Couldn't save the carbs", carbsLogged: false))
        #expect(h.treatments.enacted == [1])

        #expect(h.reporter.states == [
            "r1:pending", "r1:logged", "r2:pending", "r2:failed", "r3:pending", "r3:failed"
        ])
        // Each carry-out's marker is gone with its final report.
        #expect(!FileManager.default.fileExists(
            atPath: h.files.pending.deletingLastPathComponent().appendingPathComponent("carrying-out.json").path
        ))
    }

    @Test func watchConfirmForAReplacedOrUnknownRequestLogsNothing() async {
        let h = makeCoordinator()
        #expect(await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)) == nil)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)) == nil)
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.coordinator.current.value?.request.id == "r2")
        #expect(h.reporter.states == ["r1:pending", "r1:replaced", "r2:pending"])
    }

    @Test func watchConfirmWithCarbsOverTheMaxStoresNothing() async {
        // The watch's own carbs weren't checked when the request arrived.
        let h = makeCoordinator(limits: AIRequestLimits(maxCarbs: 50, maxFat: 250, maxProtein: 250, maxBolus: 10))
        await h.coordinator.receive(meal(id: "r1", carbs: 20), via: .service)
        let report = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: 80))
        #expect(report == .failed(reason: "Over your max carbs (50 g)", carbsLogged: false))
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.reports.last?.report == report)
    }

    @Test func secondWatchConfirmWaitsForTheFirstCarryOut() async {
        let h = makeCoordinator(dose: 1.2)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let second = TestBox<Task<AIRequestReport?, Never>?>(nil)
        h.treatments.whileEnactingBolus = { [coordinator = h.coordinator, backup = h.backup] in
            // While the pump takes r1's bolus, r2 arrives and the watch confirms it.
            await coordinator.receive(meal(id: "r2"), via: .service)
            second.value = Task {
                await coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r2", units: d("2.5"), carbs: nil))
            }
            // r2 left pending when the watch confirmed it. Give its carry-out time to run ahead of r1's bolus, if it could.
            _ = await eventuallyTrue { backup.cancelled.contains("r2") }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let first = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil))
        #expect(first == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: d("1.2"))))
        #expect(await second.value?.value == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: d("2.5"))))
        #expect(h.treatments.events == ["store r1", "enact 1.2", "enacted 1.2", "store r2", "enact 2.5", "enacted 2.5"])
        #expect(h.reporter.states == ["r1:pending", "r2:pending", "r1:delivering", "r2:delivering"])
    }

    @Test func watchConfirmAfterARelaunchActsOnTheSavedRequest() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files, now: coordinatorTestStart + 60)
        let report = await relaunched.coordinator.carryOutWatchConfirm(
            AIRequestWatchConfirm(id: "r1", units: d("1.2"), carbs: nil)
        )
        #expect(report == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: d("1.2"))))
        #expect(relaunched.treatments.stored.map(\.id) == ["r1"] && relaunched.treatments.enacted == [1.2])
        #expect(relaunched.reporter.states == ["r1:delivering"])
    }

    @Test func phoneResultReports() async {
        let started = AIRequestPhoneResult(carbs: 20, fat: 10, protein: 8, units: d("2.15"), bolus: .started)
        let carbsOnly = AIRequestPhoneResult(carbs: 20, fat: 10, protein: 8, units: 0, bolus: .none)
        let external = AIRequestPhoneResult(carbs: 20, fat: 0, protein: 0, units: 3, bolus: .external)
        let failed = AIRequestPhoneResult(carbs: 20, fat: 0, protein: 0, units: 2, bolus: .failed(reason: "Pump error"))
        let failedNoCarbs = AIRequestPhoneResult(carbs: 0, fat: 0, protein: 0, units: 2, bolus: .failed(reason: "Pump error"))
        let notStarted = AIRequestPhoneResult(carbs: 20, fat: 0, protein: 0, units: 2, bolus: .notStarted)
        let notStartedNoCarbs = AIRequestPhoneResult(carbs: 0, fat: 0, protein: 0, units: 2, bolus: .notStarted)

        #expect(
            AIRequestCoordinator.report(for: started) ==
                .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: d("2.15")))
        )
        #expect(
            AIRequestCoordinator.report(for: carbsOnly) ==
                .logged(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 0))
        )
        #expect(
            AIRequestCoordinator.report(for: external) ==
                .logged(shown: AIRequestShown(carbs: 20, fat: 0, protein: 0, units: 3))
        )
        #expect(AIRequestCoordinator.report(for: failed) == .failed(reason: "Pump error", carbsLogged: true))
        #expect(AIRequestCoordinator.report(for: failedNoCarbs) == .failed(reason: "Pump error", carbsLogged: false))
        #expect(
            AIRequestCoordinator.report(for: notStarted) ==
                .failed(reason: "The bolus wasn't started", carbsLogged: true)
        )
        #expect(
            AIRequestCoordinator.report(for: notStartedNoCarbs) ==
                .failed(reason: "The bolus wasn't started", carbsLogged: false)
        )

        // Through the coordinator, for a request the phone claimed, once.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.reportPhoneResult(id: "r1", started) // not claimed yet
        #expect(h.reporter.states == ["r1:pending"])
        #expect(await h.coordinator.claim(id: "r1", on: .phone))
        await h.coordinator.reportPhoneResult(id: "r1", started)
        await h.coordinator.reportPhoneResult(id: "r1", carbsOnly)
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
        #expect(h.reporter.reports.last?.report == AIRequestCoordinator.report(for: started))
    }

    @Test func leftHeadlines() {
        #expect(AIRequestLeftText.headline(for: .claimed(.watch), source: "ChatGPT") == ("Logged on your watch", true))
        #expect(AIRequestLeftText.headline(for: .claimed(.phone), source: "ChatGPT") == ("Logged on your iPhone", true))
        #expect(AIRequestLeftText.headline(for: .declined(.phone), source: "ChatGPT") == ("Declined on your iPhone", false))
        #expect(AIRequestLeftText.headline(for: .declined(.watch), source: "ChatGPT") == ("Declined on your watch", false))
        #expect(AIRequestLeftText.headline(for: .declined(.dismissed), source: "ChatGPT") == ("Declined on your watch", false))
        #expect(AIRequestLeftText.headline(for: .expired, source: "ChatGPT") == ("Expired", false))
        #expect(AIRequestLeftText.headline(for: .withdrawn, source: "ChatGPT") == ("Canceled by ChatGPT", false))
        #expect(AIRequestLeftText.headline(for: .replaced, source: "ChatGPT") == ("Replaced by a newer request", false))
    }

    @Test func everyWayOutSendsLeft() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r2"), via: .service) // r1 is replaced
        await h.coordinator.withdraw(id: "r2", request: nil, via: .service)
        await h.coordinator.receive(meal(id: "r3"), via: .service)
        h.now = expiresAt
        await h.coordinator.expireIfDue()
        h.now = coordinatorTestStart
        await h.coordinator.receive(meal(id: "r4"), via: .service)
        await h.coordinator.close(id: "r4", on: .phone, dismissed: false)
        await h.coordinator.receive(meal(id: "r5"), via: .service)
        #expect(await h.coordinator.claim(id: "r5", on: .phone))
        #expect(h.left == [
            LeftEvent(id: "r1", left: .replaced, source: "ChatGPT"),
            LeftEvent(id: "r2", left: .withdrawn, source: "ChatGPT"),
            LeftEvent(id: "r3", left: .expired, source: "ChatGPT"),
            LeftEvent(id: "r4", left: .declined(.phone), source: "ChatGPT"),
            LeftEvent(id: "r5", left: .claimed(.phone), source: "ChatGPT")
        ])
    }

    @Test func leftIsSentBeforeTheFinalReport() async {
        let reporter = LeftCheckingReporter()
        let h = makeCoordinator(serviceReporter: reporter)
        reporter.leftCount = { h.left.count }
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.close(id: "r1", on: .phone, dismissed: false)
        #expect(reporter.leftCountAtFinalReport == [1])
    }
}

/// A reporter that records how many `left`s were sent when each final report went out.
private final class LeftCheckingReporter: AIRequestReporter {
    private let lock = NSLock()
    private var counts: [Int] = []
    var leftCount: () -> Int = { 0 }

    var leftCountAtFinalReport: [Int] { lock.withLock { counts } }

    func report(_ report: AIRequestReport, for _: String) async {
        guard report.state != .pending else { return }
        let count = leftCount()
        lock.withLock { counts.append(count) }
    }
}

/// An exact decimal, which a `Double` literal isn't always.
private func d(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}
