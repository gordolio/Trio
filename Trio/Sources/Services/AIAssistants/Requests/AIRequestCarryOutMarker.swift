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

    /// The marker at `url`, or `nil` if there's none. An unreadable marker is logged and removed: without its ID,
    /// there's no request to report.
    static func load(from url: URL) -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            debug(.service, "AI requests: carry-out marker unreadable, dropping it: \(error)")
            remove(at: url)
            return nil
        }
    }

    /// Writes the marker atomically. A failed write is logged: the request is still carried out, as it was before
    /// Trio kept a marker.
    func save(to url: URL) {
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            debug(.service, "AI requests: couldn't save the carry-out marker for \(id): \(error)")
        }
    }

    static func remove(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            debug(.service, "AI requests: couldn't remove the carry-out marker: \(error)")
        }
    }
}
