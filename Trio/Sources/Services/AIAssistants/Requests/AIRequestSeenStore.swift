import Foundation

/// The IDs of the requests Trio has seen, kept on disk so a request is never acted on twice, even
/// after a relaunch or when the same push arrives again. Entries are dropped after `retention`.
final class AIRequestSeenStore {
    enum Sighting: Equatable {
        case new
        /// Seen before. `outcome` is `nil` while the first sighting is still being handled.
        case seen(outcome: AIRequestState?)
    }

    enum SeenError: Error, Equatable {
        case missingID
        /// The new ID couldn't be written to disk. It stays in memory, so this process still answers
        /// `.seen` for it, but a relaunch wouldn't know it.
        case persistenceFailed
    }

    private struct Entry: Codable {
        let id: String
        let firstSeen: Date
        var outcome: AIRequestState?
    }

    private let fileURL: URL
    private let now: () -> Date
    private let retention: TimeInterval
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(fileURL: URL, now: @escaping () -> Date = Date.init, retention: TimeInterval = 24 * 60 * 60) {
        self.fileURL = fileURL
        self.now = now
        self.retention = retention
        entries = load()
        dropExpired()
    }

    /// The app's store, in `Application Support/AIAssistants`.
    static func appDefault() -> AIRequestSeenStore {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("AIAssistants", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            debug(.service, "AI requests: couldn't create the seen-ID folder: \(error)")
        }
        return AIRequestSeenStore(fileURL: folder.appendingPathComponent("seen-requests.json"))
    }

    /// Records a new ID, and writes it to disk before returning `.new`. If the write fails it throws
    /// `.persistenceFailed` rather than let the request be acted on.
    func observe(_ id: String?) throws -> Sighting {
        guard let id, !id.isEmpty else { throw SeenError.missingID }
        return try lock.withLock {
            dropExpired()
            if let entry = entries.first(where: { $0.id == id }) {
                return .seen(outcome: entry.outcome)
            }
            entries.append(Entry(id: id, firstSeen: now(), outcome: nil))
            do {
                try save()
            } catch {
                debug(.service, "AI requests: couldn't save seen IDs: \(error)")
                throw SeenError.persistenceFailed
            }
            return .new
        }
    }

    /// Saves the final state of an observed request, so a repeat can be answered with it.
    func setOutcome(_ state: AIRequestState, for id: String) {
        lock.withLock {
            dropExpired()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].outcome = state
            do {
                try save()
            } catch {
                debug(.service, "AI requests: couldn't save seen IDs: \(error)")
            }
        }
    }

    private func dropExpired() {
        let cutoff = now().addingTimeInterval(-retention)
        entries.removeAll { $0.firstSeen < cutoff }
    }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try Self.makeDecoder().decode([Entry].self, from: data)
        } catch {
            debug(.service, "AI requests: seen-ID file unreadable, starting empty: \(error)")
            return []
        }
    }

    private func save() throws {
        try Self.makeEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
