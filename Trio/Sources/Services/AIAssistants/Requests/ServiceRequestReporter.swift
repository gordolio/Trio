import Foundation

/// Sends the states of the service's requests to trio-rc (`PUT /api/v1/requests/{id}/state`). It never fails
/// the coordinator: a report that can't be sent is logged and dropped. The service lists a request that isn't
/// final again at the next check-in, and the coordinator then sends its report again.
final class ServiceRequestReporter: AIRequestReporter {
    /// How long to wait before sending a report again when Trio is offline.
    static let retryDelay: Duration = .seconds(5)

    private let api: AIAssistantsAPIClient
    private let sleep: (Duration) async -> Void

    init(
        api: AIAssistantsAPIClient,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.sleep = sleep
    }

    func report(_ report: AIRequestReport, for id: String) async {
        let body = AIRequestStateBody(report)
        var failure = await send(body, for: id)
        if (failure as? AIAssistantsAPIError) == .network {
            await sleep(Self.retryDelay)
            failure = await send(body, for: id)
        }
        if let failure {
            log(failure, reporting: report.state, for: id)
        }
    }

    /// Returns the error, or `nil` once the service has the report.
    private func send(_ body: AIRequestStateBody, for id: String) async -> Error? {
        do {
            try await api.putRequestState(id: id, body)
            return nil
        } catch {
            return error
        }
    }

    /// Logs the request ID and the state, nothing else of the report.
    private func log(_ error: Error, reporting state: AIRequestState, for id: String) {
        switch error as? AIAssistantsAPIError {
        case .http(409, _)?:
            debug(.remote, "AI requests: \(id) is already final on the service, dropped its \(state.rawValue) report")
        case .network?:
            debug(.remote, "AI requests: couldn't report \(id) as \(state.rawValue), offline")
        case .signedOut?:
            debug(.remote, "AI requests: couldn't report \(id) as \(state.rawValue), signed out")
        default:
            debug(.remote, "AI requests: couldn't report \(id) as \(state.rawValue): \(error)")
        }
    }
}
