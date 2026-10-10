import CoreData
import Foundation
import SwiftUI
import Swinject
import Testing
@testable import Trio
import UIKit
import XCTest

@Suite("Nightscout backfill", .serialized) struct NightscoutBackfillTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func detectsHistoricalGapsWithFreshLatestReading() {
        let dates = [0, -300, -1200, -1500].map { now.addingTimeInterval(Double($0)) }
        #expect(GlucoseBackfillGaps.hasMissingReadings(dates: dates, now: now))
    }

    @Test func toleratesNormalCadenceAndTimestampJitter() {
        let dates = [-30, -340, -650, -950].map { now.addingTimeInterval(Double($0)) }
        #expect(!GlucoseBackfillGaps.hasMissingReadings(dates: dates, now: now))
    }

    @Test func detectsStaleAndEmptyHistoryWithoutInventingLeadingGaps() {
        #expect(GlucoseBackfillGaps.hasMissingReadings(dates: [], now: now))
        #expect(GlucoseBackfillGaps.hasMissingReadings(dates: [now.addingTimeInterval(-451)], now: now))
        #expect(!GlucoseBackfillGaps.hasMissingReadings(dates: [now], now: now))
        #expect(!GlucoseBackfillGaps.hasMissingReadings(dates: [now.addingTimeInterval(-450)], now: now))
        #expect(!GlucoseBackfillGaps.hasMissingReadings(
            dates: [now.addingTimeInterval(-90000), now, now.addingTimeInterval(600)], now: now
        ))
    }

    @MainActor @Test func showsCountThenZeroAndRefreshesConfiguration() async {
        var count = 12
        var configured = true
        let backfill = NightscoutBackfill(configuration: { configured }, operation: { count })
        backfill.refreshConfiguration()
        #expect(backfill.isConfigured)
        await backfill.run()
        #expect(backfill.feedback?.title == String(localized: "12 glucose readings added"))
        #expect(backfill.feedback?.isError == false)
        #expect(!backfill.isRunning)
        count = 0
        await backfill.run()
        #expect(backfill.feedback?.title == String(localized: "No new readings found"))
        configured = false
        backfill.refreshConfiguration()
        #expect(!backfill.isConfigured)
    }

    @MainActor @Test func reportsFailureAndClearsItAfterRetry() async {
        var fails = true
        let backfill = NightscoutBackfill(configuration: { true }) {
            if fails {
                throw URLError(.notConnectedToInternet)
            }
            return 1
        }
        await backfill.run()
        #expect(backfill.feedback?.isError == true)
        #expect(backfill.feedback?.detail == String(localized: "No internet connection. Check your connection and try again."))
        #expect(!backfill.isRunning)
        fails = false
        await backfill.run()
        #expect(backfill.feedback?.title == String(localized: "1 glucose reading added"))
        #expect(backfill.feedback?.isError == false)
        backfill.dismissFeedback()
        #expect(backfill.feedback == nil)
    }

    @MainActor @Test func coalescesRepeatedTaps() async {
        var calls = 0
        var continuation: CheckedContinuation<Int, Never>?
        let backfill = NightscoutBackfill(configuration: { true }) {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { await backfill.run() }
        while continuation == nil {
            await Task.yield()
        }
        #expect(backfill.isRunning)
        await backfill.run()
        #expect(calls == 1)
        continuation?.resume(returning: 3)
        await first.value
        #expect(!backfill.isRunning)
    }

    @Test(arguments: [401, 403, 500]) func httpFailuresAreNotEmptySuccess(status: Int) async throws {
        let api = makeAPI(status: status, body: "[]")
        await #expect(throws: NightscoutBackfillError.self) { try await api.fetch(since: now) }
    }

    @Test func emptyResponseSucceedsAndMalformedResponseThrows() async throws {
        #expect(try await makeAPI(status: 200, body: "[]").fetch(since: now).isEmpty)
        await #expect(throws: DecodingError.self) {
            try await makeAPI(status: 200, body: "not JSON").fetch(since: now)
        }
    }

    private func makeAPI(status: Int, body: String) -> NightscoutBackfillClient {
        BackfillURLProtocol.status = status
        BackfillURLProtocol.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackfillURLProtocol.self]
        return NightscoutBackfillClient(url: URL(string: "https://backfill.invalid")!, session: URLSession(configuration: configuration))
    }
}

@Suite("Nightscout backfill storage", .serialized) struct NightscoutBackfillStorageTests {
    @MainActor @Test func countsOnlyInsertedReadingsAndRespectsDeletions() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let storage = BaseGlucoseStorage(resolver: TrioApp.resolver, contextProvider: { context })
        let now = Date()
        func reading(_ minutesAgo: Double) -> BloodGlucose {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            return BloodGlucose(date: Decimal(date.timeIntervalSince1970 * 1000), dateString: date, glucose: 120)
        }
        try await storage.storeGlucose([reading(5)])
        try await context.perform {
            let deleted = DeletedGlucoseStored(context: context)
            deleted.date = now.addingTimeInterval(-15 * 60)
            deleted.glucose = 120
            deleted.isManualGlucoseEntry = false
            try context.save()
        }
        let values = [reading(5), reading(10), reading(10), reading(15), reading(20)]
        #expect(try await storage.backfillGlucoseReportingCount(values) == 2)
        #expect(try await storage.backfillGlucoseReportingCount(values) == 0)
        #expect(try await storage.backfillGlucoseReportingCount([]) == 0)
        let count = try await context.perform { try context.count(for: GlucoseStored.fetchRequest()) }
        #expect(count == 3)
    }

    @Test func propagatesSaveFailure() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let reading = BloodGlucose(date: 123, dateString: Date(), glucose: 120)
        await #expect(throws: CocoaError.self) {
            try await NightscoutBackfillStore.store([reading], in: context) { _ in
                throw CocoaError(.persistentStoreSave)
            }
        }
    }
}

private final class BackfillURLProtocol: URLProtocol {
    static var status = 200
    static var body = Data()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor final class NightscoutBackfillLayoutTests: XCTestCase {
    func testSmallScreenLayouts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backfill-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [320.0, 375.0, 440.0] {
            for dark in [false, true] {
                for snoozed in [false, true] {
                    let backfill = NightscoutBackfill(configuration: { true }, operation: { 12 })
                    backfill.refreshConfiguration()
                    let container = Container()
                    container.register(NightscoutBackfill.self) { _ in backfill }
                    let state = Home.StateModel()
                    state.currentIOB = 1.13
                    let home = Home.RootView(
                        resolver: container,
                        state: state,
                        alarmsSnoozeUntil: snoozed ? Date().addingTimeInterval(120 * 60) : .distantPast
                    )
                    let scheme: ColorScheme = dark ? .dark : .light
                    let content = VStack(spacing: 24) {
                        home.mealPanel().frame(height: HomeLayout.mealSlotHeight)
                        home.mealPanel().frame(height: HomeLayout.mealSlotHeight).dynamicTypeSize(.xxLarge)
                        NightscoutBackfillSettingsButton(backfill: backfill, isConnecting: false)
                        GlucoseBackfillToast(backfill: backfill)
                    }
                    .padding(.vertical, 24)
                    .frame(width: width)
                    .background(AppState().trioBackgroundColor(for: scheme))
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, scheme)
                    .tint(Color.tabBar)
                    await backfill.run()
                    let image = try await capture(content, width: width, dark: dark)
                    let name = "\(Int(width))-\(dark ? "dark" : "light")-\(snoozed ? "snoozed" : "active")"
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTAssertEqual(image.size.width, width)
                }
            }
        }
        print("Backfill screenshots: \(directory.path)")
    }

    func testStandardConfirmation() async throws {
        for dark in [false, true] {
            let backfill = NightscoutBackfill(configuration: { true }, operation: { 0 })
            backfill.refreshConfiguration()
            let content = GlucoseBackfillButton(backfill: backfill, hasMissingReadings: true, showConfirmation: true)
                .frame(width: 375, height: 600, alignment: .topTrailing)
                .background(Color(uiColor: .systemBackground))
                .tint(Color.tabBar)
            let image = try await capture(content, width: 375, dark: dark, expectAlert: true)
            let attachment = XCTAttachment(image: image)
            attachment.name = dark ? "confirmation-dark" : "confirmation-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testResultStates() async throws {
        for dark in [false, true] {
            for fails in [false, true] {
                let backfill = NightscoutBackfill(configuration: { true }) {
                    if fails { throw URLError(.notConnectedToInternet) }
                    return 0
                }
                backfill.refreshConfiguration()
                await backfill.run()
                let content = VStack(spacing: 20) {
                    NightscoutBackfillSettingsButton(backfill: backfill, isConnecting: false)
                    GlucoseBackfillToast(backfill: backfill)
                }
                .padding(.vertical, 24)
                .frame(width: 375)
                .background(Color(uiColor: .systemBackground))
                .tint(Color.tabBar)
                let image = try await capture(content, width: 375, dark: dark)
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(fails ? "error" : "zero")-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func capture<V: View>(_ content: V, width: CGFloat, dark: Bool, expectAlert: Bool = false) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content.preferredColorScheme(dark ? .dark : .light))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        host.view.layoutIfNeeded()
        if expectAlert { XCTAssertNotNil(host.presentedViewController) }
        return UIGraphicsImageRenderer(size: size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
