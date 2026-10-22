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
        /// The IDs on disk can't be read yet, as before the first unlock. Nothing was recorded.
        case notReadableYet
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
    /// Whether the IDs on disk were read. Before the first unlock the file is there but can't be read: it's read again
    /// at the next use, and nothing is recorded or written over it until it has been.
    private var isLoaded = false

    init(fileURL: URL, now: @escaping () -> Date = Date.init, retention: TimeInterval = 24 * 60 * 60) {
        self.fileURL = fileURL
        self.now = now
        self.retention = retention
        loadIfNeeded()
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
    /// `.persistenceFailed` rather than let the request be acted on. It throws `.notReadableYet` while the IDs on disk
    /// can't be read, since the ID may be among them.
    func observe(_ id: String?) throws -> Sighting {
        guard let id, !id.isEmpty else { throw SeenError.missingID }
        return try lock.withLock {
            loadIfNeeded()
            guard isLoaded else { throw SeenError.notReadableYet }
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
            loadIfNeeded()
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

    /// Reads the IDs on disk, unless they were read already. A file that can't be read yet is left for the next try;
    /// one that doesn't decode is started over.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        switch AIRequestFileContents.read(fileURL) {
        case .absent:
            entries = []
        case let .data(data):
            do {
                entries = try Self.makeDecoder().decode([Entry].self, from: data)
            } catch {
                debug(.service, "AI requests: seen-ID file doesn't decode, starting empty: \(error)")
                entries = []
            }
        case .unreadable:
            return
        }
        isLoaded = true
        dropExpired()
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

/// A file Trio keeps for AI requests, as read from disk.
enum AIRequestFileContents {
    case absent
    case data(Data)
    /// The file is there but can't be read yet, as before the first unlock, when protected files can't be read. It's
    /// kept, to be read again.
    case unreadable

    static func read(_ url: URL) -> AIRequestFileContents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            return try .data(Data(contentsOf: url))
        } catch {
            debug(.service, "AI requests: couldn't read \(url.lastPathComponent) yet, keeping it: \(error)")
            return .unreadable
        }
    }
}
