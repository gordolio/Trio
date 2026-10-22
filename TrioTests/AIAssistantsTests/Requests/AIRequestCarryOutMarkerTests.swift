import Foundation
import Testing

@testable import Trio

@Suite("AI request carry-out marker") struct AIRequestCarryOutMarkerTests {
    @Test func markerIsGoneAfterAFinalReport() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        _ = await h.coordinator.carryOutWatchConfirm(confirm("a"))
        #expect(h.reporter.reports(for: "a").last == .delivering(shown: h.prompt("a").shown))
        #expect(!FileManager.default.fileExists(atPath: markerURL(h.files).path))
    }

    @Test func markerFollowsEachStageOfTheCarryOut() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        let url = markerURL(h.files)
        let markers = TestBox<[AIRequestCarryOutMarker?]>([])
        h.treatments.whileStoringCarbs = { markers.value.append(AIRequestCarryOutMarker.load(from: url)) }
        h.treatments.whileEnactingBolus = { markers.value.append(AIRequestCarryOutMarker.load(from: url)) }
        _ = await h.coordinator.carryOutWatchConfirm(confirm("a"))
        #expect(markers.value.map { $0?.stage } == [.storingCarbs, .enacting])
        #expect(markers.value.first == AIRequestCarryOutMarker(
            id: "a",
            channel: .service,
            title: h.prompt("a").title,
            source: "ChatGPT",
            shown: h.prompt("a").shown,
            askedOn: .watch,
            approvedOn: .watch,
            stage: .storingCarbs
        ))
    }

    @Test func anotherRequestsFinalReportKeepsTheMarker() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        let url = markerURL(h.files)
        let marker = TestBox<AIRequestCarryOutMarker?>(nil)
        h.treatments.whileEnactingBolus = { [coordinator = h.coordinator] in
            // While the pump takes a's bolus, b arrives and is declined.
            await coordinator.receive(meal(id: "b"), via: .service)
            await coordinator.close(id: "b", on: .phone, dismissed: false)
            marker.value = AIRequestCarryOutMarker.load(from: url)
        }
        _ = await h.coordinator.carryOutWatchConfirm(confirm("a"))
        #expect(h.reporter.reports(for: "b").last == .declined(on: .phone))
        #expect(marker.value?.id == "a" && marker.value?.stage == .enacting)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [
        (AIRequestCarryOutMarker.Stage.checking, false, "Trio stopped before it finished"),
        (.storingCarbs, true, "Trio stopped before it finished"), // the save may have landed, so say it did
        (.enacting, true, "Trio stopped while starting the bolus. It may have been given")
    ]) func launchWithAMarkerReportsAFailure(
        stage: AIRequestCarryOutMarker.Stage,
        carbsLogged: Bool,
        reason: String
    ) async throws {
        let files = CoordinatorFiles.temporary()
        // The request was seen before Trio stopped.
        _ = try AIRequestSeenStore(fileURL: files.seen, now: { coordinatorTestStart }).observe("a")
        leftoverMarker(id: "a", stage: stage).save(to: markerURL(files))
        let service = RecordingReporter()
        let h = makeCoordinator(files: files, serviceReporter: service)
        await h.coordinator.start()
        let failed = AIRequestReport.failed(reason: reason, carbsLogged: carbsLogged)
        #expect(service.reports(for: "a") == [failed])
        #expect(h.reporter.reports.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: markerURL(files).path))
        // A repeat of the request gets the same report, and nothing is given.
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(service.reports(for: "a") == [failed, failed])
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func approvalBeforeStartReportsTheLeftoverMarkerFirst() async {
        // `start()` runs in a task at launch, so a confirmation can reach the coordinator before it.
        let files = CoordinatorFiles.temporary()
        leftoverMarker(id: "a", stage: .enacting).save(to: markerURL(files))
        let h = makeCoordinator(files: files)
        await h.coordinator.receive(meal(id: "b"), via: .service)
        _ = await h.coordinator.carryOutWatchConfirm(confirm("b"))
        await h.coordinator.start()
        #expect(h.reporter.states == ["b:pending", "a:failed", "b:delivering"])
        #expect(h.treatments.enacted == [1.2])
        #expect(!FileManager.default.fileExists(atPath: markerURL(files).path))
    }

    @Test func markerOfAReportedRequestIsOnlyRemoved() async {
        // Trio stopped after saving the final report, before removing the marker.
        let files = CoordinatorFiles.temporary()
        let first = makeCoordinator(files: files)
        await first.coordinator.receive(meal(id: "a"), via: .service)
        _ = await first.coordinator.carryOutWatchConfirm(confirm("a"))
        leftoverMarker(id: "a", stage: .enacting).save(to: markerURL(files))
        let relaunched = makeCoordinator(files: files)
        await relaunched.coordinator.start()
        #expect(relaunched.reporter.reports.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: markerURL(files).path))
    }

    @Test func unreadableMarkerIsDropped() throws {
        let files = CoordinatorFiles.temporary()
        try Data("not a marker".utf8).write(to: markerURL(files))
        #expect(AIRequestCarryOutMarker.load(from: markerURL(files)) == nil)
        #expect(!FileManager.default.fileExists(atPath: markerURL(files).path))
    }

    @Test func markerThatCantBeReadYetIsKeptAndReportedOnceItCanBe() async throws {
        // Before the first unlock, an intact protected file can't be read.
        let files = CoordinatorFiles.temporary()
        let url = markerURL(files)
        _ = try AIRequestSeenStore(fileURL: files.seen, now: { coordinatorTestStart }).observe("a")
        leftoverMarker(id: "a", stage: .enacting).save(to: url)
        try setReadable(url, false)
        #expect(AIRequestCarryOutMarker.read(from: url) == .unreadable)
        let service = RecordingReporter()
        let h = makeCoordinator(files: files, serviceReporter: service)
        await h.coordinator.start()
        #expect(service.reports(for: "a").isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))

        try setReadable(url, true)
        await h.coordinator.start()
        let failed = AIRequestReport.failed(
            reason: "Trio stopped while starting the bolus. It may have been given",
            carbsLogged: true
        )
        #expect(service.reports(for: "a") == [failed])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func approvalWhileTheMarkerCantBeReadKeepsItForTheNextApproval() async throws {
        let files = CoordinatorFiles.temporary()
        let url = markerURL(files)
        leftoverMarker(id: "a", stage: .enacting).save(to: url)
        try setReadable(url, false)
        let h = makeCoordinator(files: files)
        await h.coordinator.start()
        // b is carried out with its marker in memory only, so the one Trio left isn't written over.
        await h.coordinator.receive(meal(id: "b"), via: .service)
        _ = await h.coordinator.carryOutWatchConfirm(confirm("b"))
        #expect(h.reporter.states == ["b:pending", "b:delivering"])
        try setReadable(url, true)
        #expect(AIRequestCarryOutMarker.load(from: url) == leftoverMarker(id: "a", stage: .enacting))

        // The next approval reads it again, and reports it before its own marker takes the file.
        await h.coordinator.receive(meal(id: "c"), via: .service)
        _ = await h.coordinator.carryOutWatchConfirm(confirm("c"))
        #expect(h.reporter.states == ["b:pending", "b:delivering", "c:pending", "a:failed", "c:delivering"])
        #expect(h.treatments.enacted == [1.2, 1.2])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// The watch's confirmation of Trio's 1.2 U dose for `meal(id:)`, with its own carbs.
private func confirm(_ id: String) -> AIRequestWatchConfirm {
    AIRequestWatchConfirm(id: id, units: 1.2, carbs: nil)
}

/// Where the coordinator keeps its carry-out marker: next to the pending file.
private func markerURL(_ files: CoordinatorFiles) -> URL {
    files.pending.deletingLastPathComponent().appendingPathComponent("carrying-out.json")
}

/// The marker a coordinator left for `meal(id:)`, asked and approved on the watch, when Trio stopped at `stage`.
private func leftoverMarker(id: String, stage: AIRequestCarryOutMarker.Stage) -> AIRequestCarryOutMarker {
    let request = meal(id: id)
    return AIRequestCarryOutMarker(
        id: id,
        channel: .service,
        title: "\(request.source): \(request.description)",
        source: request.source,
        shown: AIRequestShown(carbs: request.carbs, fat: request.fat, protein: request.protein, units: 1.2),
        askedOn: .watch,
        approvedOn: .watch,
        stage: stage
    )
}
