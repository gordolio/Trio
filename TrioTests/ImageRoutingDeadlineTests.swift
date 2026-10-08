import Foundation
import Testing

@testable import Trio

@Suite("Image routing total deadlines", .serialized) struct ImageRoutingDeadlineTests {
    @Test("Trickling decision bytes cannot extend the total deadline") func tricklingDecision() async throws {
        TricklingAIURLProtocol.reset(streaming: false)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let service = OpenRouterImageDecisionService(session: session, deadline: .milliseconds(400), apiKey: { "fixture-key" })
        let start = ContinuousClock.now
        await #expect(throws: Error.self) {
            try await service.classify(imageData: Data([1]), modelID: "fixture/classifier", sessionID: "capture")
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(TricklingAIURLProtocol.sentChunks >= 2)
        try await waitForCancellation()
    }

    @Test("Label progress and SSE keepalives cannot extend the total deadline") func tricklingLabelStream() async throws {
        TricklingAIURLProtocol.reset(streaming: true)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let service = OpenRouterService(
            modelID: "fixture/label", session: session, requireCompleteNutrition: true,
            analysisDeadline: .milliseconds(400), apiKey: { "fixture-key" }
        )
        let start = ContinuousClock.now
        var receivedPartial = false
        await #expect(throws: Error.self) {
            for try await partial in service.analyzeFoodStreaming(
                imageData: Data([1]),
                userDescription: nil,
                sessionID: "capture"
            ) {
                receivedPartial = receivedPartial || !partial.foodItems.isEmpty
            }
        }
        #expect(receivedPartial)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(TricklingAIURLProtocol.sentChunks >= 2)
        try await waitForCancellation()
    }

    @Test("DONE completes the label stream even when the connection stays open") func completedLabelStream() async throws {
        TricklingAIURLProtocol.reset(streaming: true, doneDelay: 0.1, closeAtDone: false)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let service = OpenRouterService(
            modelID: "fixture/label", session: session, requireCompleteNutrition: true,
            analysisDeadline: .milliseconds(400), apiKey: { "fixture-key" }
        )
        var completed = false
        for try await partial in service.analyzeFoodStreaming(imageData: Data([1]), userDescription: nil, sessionID: "capture") {
            completed = completed || partial.isComplete
        }
        #expect(completed)
        try await waitForCancellation()
    }

    @Test("User cancellation closes the label transport") func cancelledLabelTransport() async throws {
        TricklingAIURLProtocol.reset(streaming: true)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let service = OpenRouterService(
            modelID: "fixture/label", session: session, requireCompleteNutrition: true,
            analysisDeadline: .seconds(30), apiKey: { "fixture-key" }
        )
        let reader = Task {
            for try await _ in service.analyzeFoodStreaming(imageData: Data([1]), userDescription: nil, sessionID: "capture") {}
        }
        let limit = ContinuousClock.now.advanced(by: .seconds(1))
        while TricklingAIURLProtocol.sentChunks < 2, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TricklingAIURLProtocol.sentChunks >= 2)
        reader.cancel()
        _ = await reader.result
        try await waitForCancellation()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TricklingAIURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func waitForCancellation() async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(1))
        while !TricklingAIURLProtocol.wasCancelled, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TricklingAIURLProtocol.wasCancelled)
    }
}

private final class TricklingAIURLProtocol: URLProtocol {
    private static let fixtureLock = NSLock()
    private static var streaming = false
    private static var doneDelay: TimeInterval = 1.2
    private static var closeAtDone = true
    private static var chunks = 0
    private static var cancelled = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ImageRoutingDeadlineTests.transport")
    private var stopped = false
    private var work: [DispatchWorkItem] = []

    static var sentChunks: Int { fixtureLock.withLock { chunks } }
    static var wasCancelled: Bool { fixtureLock.withLock { cancelled } }
    static func reset(streaming: Bool, doneDelay: TimeInterval = 1.2, closeAtDone: Bool = true) {
        fixtureLock.withLock { self.streaming = streaming
            self.doneDelay = doneDelay
            self.closeAtDone = closeAtDone
            chunks = 0
            cancelled = false }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let isStream = Self.fixtureLock.withLock { Self.streaming }
        let completionDelay = Self.fixtureLock.withLock { Self.doneDelay }
        let closeOnCompletion = Self.fixtureLock.withLock { Self.closeAtDone }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"]
        )!, cacheStoragePolicy: .notAllowed)
        if isStream {
            let content =
                #"{"foodItems":[{"name":"Crackers","carbs":22,"fat":4,"protein":3,"servingCount":4,"servingUnit":"Crackers"}],"overallConfidence":0.99,"reasoning":"label"}"#
            let payload = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
            send(Data("data: \(String(decoding: payload, as: UTF8.self))\n\n".utf8))
        }
        for index in 0 ..< 30 {
            schedule(after: Double(index) * 0.04) { [weak self] in
                self?.send(Data((isStream ? ": keepalive\n\n" : " ").utf8))
            }
        }
        schedule(after: completionDelay) { [weak self] in
            guard let self else { return }
            let end = isStream ? "data: [DONE]\n\n" :
                #"{"answers":{"route":{"type":"choice","choice":"food","probabilities":{"food":0.98,"nutrition_label":0.01,"uncertain":0.01}}}}"#
            self.send(Data(end.utf8))
            if closeOnCompletion, !self.lock.withLock({ self.stopped }) { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }

    private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        let item = DispatchWorkItem(block: action)
        lock.withLock { work.append(item) }
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func send(_ data: Data) {
        guard !lock.withLock({ stopped }) else { return }
        Self.fixtureLock.withLock { Self.chunks += 1 }
        client?.urlProtocol(self, didLoad: data)
    }

    override func stopLoading() {
        let items = lock.withLock { stopped = true
            return work }
        items.forEach { $0.cancel() }
        Self.fixtureLock.withLock { Self.cancelled = true }
    }
}
