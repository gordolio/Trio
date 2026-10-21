import Foundation

/// Sends the wearer's signed answer along the request's answer route: to the phone over WatchConnectivity,
/// to the service with the request's one-time answer token, or both. Nothing is retried. The phone takes
/// the first valid answer and ignores any other copy.
enum AIRequestAnswerSender {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    /// `inBackground` is for an answer from a notification action, which also queues the WatchConnectivity copy
    /// as user info. `completion` runs once WatchConnectivity has the answer and the service has responded.
    ///
    /// Returns what it can know as it hands the answer off: `.sent` when the service is sent it or the phone was
    /// reachable, `.queued` when it can only wait in WatchConnectivity's queue for the phone, and `.notSent` when it
    /// couldn't be encoded. Whether the service took it isn't known until later: the phone's receipt says so.
    @discardableResult static func send(
        _ answer: AIRequestAnswer,
        prompt: AIRequestPrompt,
        inBackground: Bool = false,
        completion: @escaping () -> Void = {}
    ) -> AIRequestSendResult {
        let body: Data
        do {
            body = try JSONEncoder().encode(answer)
        } catch {
            Task { await WatchLogger.shared.log("AI requests: couldn't encode the answer to \(prompt.id): \(error)") }
            completion()
            return .notSent
        }

        let sent = DispatchGroup()
        let serviceRequest = prompt.answerRoute == .watchOnly ? nil : request(body, prompt: prompt)
        var reachedPhone = false
        // The answer goes back over WatchConnectivity whenever the service can't take it, whatever the route
        // says. A request that came from the phone over WatchConnectivity has no answer token.
        if prompt.answerRoute != .serviceOnly || serviceRequest == nil {
            reachedPhone = toPhone(body, inBackground: inBackground, sent: sent)
        }
        if let serviceRequest {
            toService(serviceRequest, id: prompt.id, sent: sent)
        }
        sent.notify(queue: .global(qos: .userInitiated), execute: completion)
        return serviceRequest != nil || reachedPhone ? .sent : .queued
    }

    /// Returns whether the answer went to the phone live, because it was reachable.
    private static func toPhone(_ body: Data, inBackground: Bool, sent: DispatchGroup) -> Bool {
        let center = AIRequestWatchCenter.shared
        center.activateSessionIfUnowned()
        sent.enter()
        return center.sendToPhone([AIRequestIdentifiers.keyAnswer: body], delivery: inBackground ? .liveAndQueued : .live) {
            sent.leave()
        }
    }

    /// The service's request for the answer, or `nil` if the prompt has no answer token or https answer URL.
    private static func request(_ body: Data, prompt: AIRequestPrompt) -> URLRequest? {
        let id = prompt.id
        guard let token = prompt.answerToken, let url = prompt.answerURL else {
            Task { await WatchLogger.shared.log("AI requests: no answer token for \(id), so the service isn't sent the answer") }
            return nil
        }
        guard url.scheme?.lowercased() == "https" else {
            Task { await WatchLogger.shared.log("AI requests: the answer URL for \(id) isn't https, so it isn't used") }
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func toService(_ request: URLRequest, id: String, sent: DispatchGroup) {
        sent.enter()
        session.dataTask(with: request) { _, response, error in
            defer { sent.leave() }
            if let error {
                Task { await WatchLogger.shared.log("AI requests: couldn't send the answer to \(id) to the service: \(error)") }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200 ..< 300).contains(status) {
                Task { await WatchLogger.shared.log("AI requests: the service took the answer to \(id)") }
            } else {
                Task { await WatchLogger.shared.log("AI requests: the service refused the answer to \(id): \(status)") }
            }
        }.resume()
    }
}
