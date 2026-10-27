import Foundation

/// The approved request Trio is carrying out, kept on disk from before its checks until its final report. A launch
/// that finds it knows Trio stopped partway, and reports the request failed, saying whether the carbs may have
/// been logged and the bolus started.
struct AIRequestCarryOutMarker: Codable, Equatable {
    enum Stage: String, Codable {
        /// Running the checks. Nothing was stored.
        case checking
        /// Saving the carbs, which may have landed.
        case storingCarbs
        /// Starting the bolus, which the pump may have taken.
        case enacting
    }

    let id: String
    let channel: AIRequestChannel
    let title: String
    let source: String
    let shown: AIRequestShown
    let askedOn: AIRequestAskedOn
    let approvedOn: AIRequestAnswerSide
    var stage: Stage

    /// What's on disk where a marker is kept.
    enum Reading: Equatable {
        case absent
        case found(AIRequestCarryOutMarker)
        /// The file is there but couldn't be read yet, as before the first unlock, when protected files can't be
        /// read. It's kept, to be read again.
        case unreadable
    }

    /// Reads the marker at `url`. A file that reads but doesn't decode is logged and removed: without its ID,
    /// there's no request to report. A file that can't be read is kept: at `.enacting`, it's the only record that
    /// a bolus may have started.
    static func read(from url: URL) -> Reading {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            debug(.remote, "AI requests: couldn't read the carry-out marker yet, keeping it: \(error)")
            return .unreadable
        }
        do {
            return try .found(JSONDecoder().decode(Self.self, from: data))
        } catch let error as DecodingError {
            debug(.remote, "AI requests: carry-out marker doesn't decode, dropping it: \(error)")
            remove(at: url)
            return .absent
        } catch {
            debug(.remote, "AI requests: couldn't decode the carry-out marker, keeping it: \(error)")
            return .unreadable
        }
    }

    /// The marker at `url`, or `nil` if there's none or it can't be read yet. See `read(from:)`.
    static func load(from url: URL) -> Self? {
        guard case let .found(marker) = read(from: url) else { return nil }
        return marker
    }

    /// Writes the marker atomically. A failed write is logged: the request is still carried out, as it was before
    /// Trio kept a marker.
    func save(to url: URL) {
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            debug(.remote, "AI requests: couldn't save the carry-out marker for \(id): \(error)")
        }
    }

    static func remove(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            debug(.remote, "AI requests: couldn't remove the carry-out marker: \(error)")
        }
    }
}
