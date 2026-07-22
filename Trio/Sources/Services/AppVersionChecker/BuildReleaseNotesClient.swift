import Foundation

struct BuildReleaseNotes: Decodable, Equatable, Sendable {
    struct Metadata: Decodable, Equatable, Sendable {
        let shortSha: String
        let buildDate: String
    }

    struct Source: Decodable, Equatable, Sendable {
        let id: String
        let title: String
        let url: URL
    }

    struct Item: Decodable, Equatable, Sendable {
        let changeIds: [String]
        let title: String
        let changes: [String]
        let provenance: String
        let confidence: String
        let humanReviewRequired: Bool
        let highlight: Bool
        let sources: [Source]
    }

    struct Category: Decodable, Equatable, Sendable {
        let category: String
        let title: String
        let items: [Item]
    }

    let schemaVersion: String
    let metadata: Metadata
    let highlights: [Item]
    let categories: [Category]
    let maintenanceHotspots: [String]
}

actor BuildReleaseNotesClient {
    static let shared = BuildReleaseNotesClient()

    private let baseURL = URL(
        string: "https://raw.githubusercontent.com/gordolio/Trio-release-notes/main/public/builds/"
    )!

    func fetch(commitSHA: String) async -> BuildReleaseNotes? {
        let sha = commitSHA.lowercased()
        guard sha.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else {
            return nil
        }

        let url = baseURL.appendingPathComponent("\(sha).json")
        for attempt in 0 ..< 3 {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return nil
                }
                if httpResponse.statusCode == 404, attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                    continue
                }
                guard httpResponse.statusCode == 200,
                      data.count <= 2 * 1024 * 1024
                else {
                    return nil
                }

                let notes = try JSONDecoder().decode(BuildReleaseNotes.self, from: data)
                let sourceURLs = notes.highlights.flatMap(\.sources) + notes.categories.flatMap { $0.items.flatMap(\.sources) }
                guard notes.schemaVersion == "2",
                      notes.metadata.shortSha.lowercased() == sha,
                      sourceURLs.allSatisfy({ $0.url.scheme == "https" && $0.url.host == "github.com" })
                else {
                    return nil
                }
                return notes
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }
}
