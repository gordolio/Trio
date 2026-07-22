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
        string: "https://raw.githubusercontent.com/gordolio/Trio-release-notes/main/public/"
    )!
    private var cachedBuilds: [BuildReleaseNotes]?

    func fetchRecentBuilds(limit: Int = 100) async -> [BuildReleaseNotes] {
        if let cachedBuilds {
            return cachedBuilds
        }

        guard let latest = await fetch(relativePath: "latest.json") else {
            return []
        }

        var builds = [latest]
        var visited = Set([latest.metadata.shortSha.lowercased()])
        var current = latest

        while builds.count < limit,
              let previousBuiltSha = current.metadata.previousBuiltSha,
              let previousShortSha = shortSHA(previousBuiltSha),
              visited.insert(previousShortSha).inserted,
              let previous = await fetch(
                  relativePath: "builds/\(previousShortSha).json",
                  expectedShortSHA: previousShortSha
              )
        {
            builds.append(previous)
            current = previous
        }

        cachedBuilds = builds
        return builds
    }

    private func fetch(relativePath: String, expectedShortSHA: String? = nil) async -> BuildReleaseNotes? {
        let url = baseURL.appendingPathComponent(relativePath)

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count <= 2 * 1024 * 1024
            else {
                return nil
            }

            let notes = try JSONDecoder().decode(BuildReleaseNotes.self, from: data)
            let sourceURLs = notes.highlights.flatMap(\.sources) + notes.categories.flatMap { category in
                category.items.flatMap(\.sources)
            }
            guard notes.schemaVersion == "2",
                  shortSHA(notes.metadata.shortSha) != nil,
                  expectedShortSHA == nil || notes.metadata.shortSha.lowercased() == expectedShortSHA,
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

    private func shortSHA(_ sha: String) -> String? {
        let normalized = sha.lowercased()
        guard normalized.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else {
            return nil
        }
        return String(normalized.prefix(7))
    }
}
