import Foundation

/// What the screen shows, worked out from the link state, the account and the build's service.
extension AIAssistantsConfig.StateModel {
    var isLinked: Bool {
        if case .linked = linkState { return true }
        return false
    }

    var sharingStatus: AIAssistantsConfig.SharingStatus? {
        guard case let .linked(_, lastUpload, lastError) = linkState else { return nil }
        if let lastError {
            return .failed(message: lastError, lastUpload: lastUpload)
        }
        return lastUpload.map { .sharing(lastUpload: $0) } ?? .waitingForFirstUpdate
    }

    /// The address people paste into an assistant: the service plus `/mcp`.
    var connectorURL: URL? {
        serviceURL?.appendingPathComponent("mcp")
    }

    /// The connector URL without `https://`, for example `trio-rc.gordol.io/mcp`.
    var connectorDisplayText: String? {
        guard let connectorURL, let host = connectorURL.host else { return nil }
        let port = connectorURL.port.map { ":\($0)" } ?? ""
        return host + port + connectorURL.path
    }

    /// Links made before Trio kept the email have none.
    var accountTitle: String {
        account?.email ?? String(localized: "Signed in with Apple")
    }

    /// The first letters of the name's first and last words, else of the email's first two parts
    /// (`gordon.child@…` → "GC").
    var initials: String? {
        let words: [Substring]
        if let name = account?.name {
            let parts = name.split(whereSeparator: \.isWhitespace)
            words = parts.count > 1 ? [parts[0], parts[parts.count - 1]] : parts
        } else if let email = account?.email, let localPart = email.split(separator: "@").first {
            words = Array(localPart.split(whereSeparator: { ".-_+".contains($0) }).prefix(2))
        } else {
            return nil
        }
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? nil : letters
    }

    /// "Updated just now" for anything under a minute old, or dated after `now` (the phone's
    /// clock is behind); otherwise "Updated 5 minutes ago".
    static func updatedText(lastUpload: Date, now: Date) -> String {
        guard now.timeIntervalSince(lastUpload) >= 60 else {
            return String(localized: "Updated just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        let relative = formatter.localizedString(for: lastUpload, relativeTo: now)
        return String(localized: "Updated \(relative)")
    }
}
