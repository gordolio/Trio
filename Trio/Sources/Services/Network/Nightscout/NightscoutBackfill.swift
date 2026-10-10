import Combine
import CoreData
import Foundation
import Swinject
import UIKit

final class NightscoutBackfill: ObservableObject {
    static func register(in container: Container) {
        container.register(NightscoutBackfill.self) { resolver in
            NightscoutBackfill(
                keychain: resolver.resolve(Keychain.self)!,
                glucoseStorage: resolver.resolve(GlucoseStorage.self)!,
                healthKitManager: resolver.resolve(HealthKitManager.self)!
            )
        }.inObjectScope(.container)
    }

    struct Feedback: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let isError: Bool
    }

    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var feedback: Feedback?

    private let configuration: () -> Bool
    private let operation: () async throws -> Int

    init(configuration: @escaping () -> Bool, operation: @escaping () async throws -> Int) {
        self.configuration = configuration
        self.operation = operation
    }

    convenience init(keychain: Keychain, glucoseStorage: GlucoseStorage, healthKitManager: HealthKitManager) {
        let api = {
            guard let urlString = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey),
                  let url = URL(string: urlString), url.scheme == "https", url.host?.isEmpty == false
            else { return nil as NightscoutBackfillClient? }
            return NightscoutBackfillClient(
                url: url,
                secret: keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
            )
        }
        self.init(configuration: { api() != nil }) {
            guard let nightscout = api() else { throw NightscoutBackfillError.notConfigured }
            let now = Date()
            let since = now.addingTimeInterval(-GlucoseBackfillGaps.lookback)
            let readings = try await nightscout.fetch(since: since)
            try Task.checkCancellation()
            let eligible = readings.filter {
                $0.dateString >= since && $0.dateString <= now &&
                    ($0.glucose ?? 0) > 0 && ($0.glucose ?? 0) <= Int(Int16.max)
            }
            let count = try await glucoseStorage.backfillGlucoseReportingCount(eligible)
            if count > 0 {
                Task { await healthKitManager.uploadGlucose() }
            }
            return count
        }
    }

    @MainActor func refreshConfiguration() {
        isConfigured = configuration()
    }

    @MainActor func run() async {
        guard !isRunning else { return }
        isRunning = true
        feedback = nil
        defer { isRunning = false }
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Backfilling glucose from Nightscout."))

        do {
            let count = try await operation()
            feedback = Feedback(
                title: count == 0 ? String(localized: "No new readings found") :
                    count == 1 ? String(localized: "1 glucose reading added") :
                    String(localized: "\(count) glucose readings added"),
                detail: String(localized: "Backfill from Nightscout completed."),
                isError: false
            )
        } catch {
            feedback = Feedback(
                title: String(localized: "Couldn't backfill glucose"),
                detail: Self.errorMessage(error),
                isError: true
            )
        }

        if let feedback {
            UIAccessibility.post(notification: .announcement, argument: feedback.title + ". " + feedback.detail)
            if !feedback.isError, !UIAccessibility.isVoiceOverRunning {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard self?.feedback?.id == feedback.id else { return }
                    self?.dismissFeedback()
                }
            }
        }
    }

    @MainActor func dismissFeedback() {
        feedback = nil
    }

    static func errorMessage(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "No internet connection. Check your connection and try again.")
            case .timedOut:
                return String(localized: "Nightscout took too long to respond. Try again.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "Unable to reach Nightscout. Check your Nightscout URL and try again.")
            default: return error.localizedDescription
            }
        }
        if error is DecodingError { return String(localized: "Nightscout returned unreadable glucose data. Try again later.") }
        if error is CoreDataError { return String(localized: "Unable to save the backfilled glucose readings. Try again.") }
        return error.localizedDescription
    }
}

enum GlucoseBackfillGaps {
    static let lookback: TimeInterval = 24 * 60 * 60
    static let missingReadingInterval: TimeInterval = 7.5 * 60

    static func hasMissingReadings(dates: [Date], now: Date) -> Bool {
        let start = now.addingTimeInterval(-lookback)
        let recent = dates.filter { $0 >= start && $0 <= now }.sorted()
        guard let last = recent.last else { return true }
        if now.timeIntervalSince(last) > missingReadingInterval {
            return true
        }
        return zip(recent, recent.dropFirst()).contains {
            $1.timeIntervalSince($0) > missingReadingInterval
        }
    }
}

enum NightscoutBackfillError: LocalizedError {
    case notConfigured
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Configure a Nightscout connection first.")
        case .invalidResponse:
            return String(localized: "Nightscout returned an unexpected response.")
        case .httpStatus(401), .httpStatus(403):
            return String(localized: "Nightscout denied access. Check your connection credentials.")
        case let .httpStatus(status):
            return String(localized: "Nightscout returned HTTP \(status). Try again later.")
        }
    }
}

struct NightscoutBackfillClient {
    let url: URL
    var secret: String?
    var session: URLSession = .shared

    func fetch(since: Date) async throws -> [BloodGlucose] {
        var components = URLComponents(url: url.appendingPathComponent("api/v1/entries/sgv.json"), resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.queryItems = [
            URLQueryItem(name: "count", value: "1600"),
            URLQueryItem(name: "find[dateString][$gte]", value: Formatter.iso8601withFractionalSeconds.string(from: since)),
        ]
        guard let requestURL = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 60
        if let secret, !secret.isEmpty {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NightscoutBackfillError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw NightscoutBackfillError.httpStatus(response.statusCode)
        }
        return try JSONCoding.decoder.decode([BloodGlucose].self, from: data).map {
            var reading = $0
            reading.glucose = $0.sgv ?? $0.mbg
            return reading
        }
    }
}

enum NightscoutBackfillStore {
    static func store(
        _ readings: [BloodGlucose],
        in context: NSManagedObjectContext,
        persist: @escaping ([BloodGlucose]) throws -> Void
    ) async throws -> Int {
        guard let first = readings.map(\.dateString).min(), let last = readings.map(\.dateString).max() else { return 0 }
        return try await context.perform {
            func dates(entity: String) throws -> [Date] {
                let request = NSFetchRequest<NSDictionary>(entityName: entity)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["date"]
                request.predicate = NSPredicate(
                    format: "date >= %@ AND date <= %@",
                    first.addingTimeInterval(-210) as NSDate,
                    last.addingTimeInterval(210) as NSDate
                )
                return try context.fetch(request).compactMap { $0["date"] as? Date }
            }
            let deleted = try dates(entity: "DeletedGlucoseStored")
            var existing = try dates(entity: "GlucoseStored")
            var additions: [BloodGlucose] = []
            for reading in readings.sorted(by: { $0.dateString < $1.dateString }) {
                guard !deleted.contains(where: { abs($0.timeIntervalSince(reading.dateString)) <= 1 }),
                      !existing.contains(where: { abs($0.timeIntervalSince(reading.dateString)) <= 210 })
                else { continue }
                additions.append(reading)
                existing.append(reading.dateString)
            }
            guard !additions.isEmpty else { return 0 }
            try persist(additions)
            return additions.count
        }
    }
}
