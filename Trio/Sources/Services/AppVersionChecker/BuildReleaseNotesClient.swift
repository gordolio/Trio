import Foundation

struct BuildReleaseNotes: Decodable, Equatable, Sendable {
    struct Metadata: Decodable, Equatable, Sendable {
        let shortSha: String
        let buildDate: String
        let previousBuiltSha: String?
        let currentBuiltSha: String?
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
        string: "https://raw.githubusercontent.com/gordolio/Trio-release-notes/main/public/builds.jsonl"
    )!
    private var cachedBuilds: [BuildReleaseNotes]?

    func fetchRecentBuilds(limit: Int = 100) async -> [BuildReleaseNotes] {
        if let cachedBuilds {
            return cachedBuilds
        }

        do {
            var request = URLRequest(url: baseURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count <= 20 * 1024 * 1024,
                  let text = String(data: data, encoding: .utf8)
            else {
                return []
            }

            let decoder = JSONDecoder()
            var builds: [BuildReleaseNotes] = []
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = line.data(using: .utf8),
                      let notes = try? decoder.decode(BuildReleaseNotes.self, from: lineData)
                else {
                    continue
                }
                guard isValid(notes) else {
                    continue
                }
                builds.append(notes)
                if builds.count >= limit {
                    break
                }
            }

            cachedBuilds = builds
            return builds
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private func isValid(_ notes: BuildReleaseNotes) -> Bool {
        let sourceURLs = notes.highlights.flatMap(\.sources) + notes.categories.flatMap { category in
            category.items.flatMap(\.sources)
        }
        return notes.schemaVersion == "2" &&
            shortSHA(notes.metadata.shortSha) != nil &&
            sourceURLs.allSatisfy { $0.url.scheme == "https" && $0.url.host == "github.com" }
    }

    private func shortSHA(_ sha: String) -> String? {
        let normalized = sha.lowercased()
        guard normalized.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else {
            return nil
        }
        return String(normalized.prefix(7))
    }
}
