import Foundation
import LocalAuthentication

/// The iPhone approval's Face ID check, and the words and icon that go with it. The check is the same policy as an
/// in-app bolus (`BaseUnlockManager`): Face ID or Touch ID, falling back to the passcode, because an unlocked phone
/// doesn't prove who is holding it. What differs is the reason on the prompt, which names the dose, so the wearer
/// sees what they are about to approve on the system's own screen too.
enum AIRequestUnlock {
    /// Asks for Face ID, Touch ID or the passcode, with `reason` on the prompt. Returns whether it passed. A failed or
    /// cancelled check throws, as `BaseUnlockManager.unlock()` does. The policy is `.deviceOwnerAuthentication`, so a
    /// device with no passcode can't pass.
    @MainActor static func unlock(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    /// The prompt's reason: "Approve a 2.10 U bolus for 35 g of carbs", or "Log 35 g of carbs" when Trio's dose is 0 U.
    static func reason(shown: AIRequestShown) -> String {
        if AIRequestContextRows.givesNoBolus(shown) {
            return String(
                localized: "Log \(shown.carbsText) of carbs",
                comment: "Face ID prompt for an iPhone approval when Trio's dose is 0 U. The placeholder is the carbs, for example '35 g'."
            )
        }
        return String(
            localized: "Approve a \(shown.unitsText) bolus for \(shown.carbsText) of carbs",
            comment: "Face ID prompt for an iPhone approval. The placeholders are the dose, for example '2.10 U', and the carbs, for example '35 g'."
        )
    }

    /// The Approve button's title and icon: "Approve 2.10 U", or "Log 35 g carbs" when Trio's dose is 0 U, with the icon
    /// of what the device unlocks with.
    static func approveLabel(shown: AIRequestShown, biometryType: LABiometryType) -> (title: String, symbol: String) {
        let title: String
        if AIRequestContextRows.givesNoBolus(shown) {
            title = String(
                localized: "Log \(shown.carbsText) carbs",
                comment: "iPhone approval button when Trio's dose is 0 U. The placeholder is the carbs, for example '35 g'."
            )
        } else {
            title = String(
                localized: "Approve \(shown.unitsText)",
                comment: "iPhone approval button. The placeholder is the dose, for example '2.10 U'."
            )
        }
        return (title, symbol(for: biometryType))
    }

    /// The SF Symbol for what the device unlocks with. The passcode, which is all a device with no biometry has, is a
    /// lock.
    static func symbol(for biometryType: LABiometryType) -> String {
        switch biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        case .none:
            return "lock"
        @unknown default:
            return "lock"
        }
    }

    /// What this device unlocks with now. The type is only filled in once the context has been asked whether it can
    /// evaluate a policy, and it is whether or not that policy can pass, so a locked-out Face ID still shows its icon.
    static func currentBiometryType() -> LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }
}

/// The amounts as the approval words them. Each number sits next to its unit with a no-break space (U+00A0), so a line
/// never breaks between them.
extension AIRequestShown {
    /// The dose as it was shown, with its two decimals: "2.10 U".
    var unitsText: String {
        String(
            localized: "\(units)\u{00A0}U",
            comment: "iPhone approval: Trio's dose in units. The no-break space keeps the number with its unit."
        )
    }

    /// The carbs without trailing zeros: "35 g".
    var carbsText: String {
        String(
            localized: "\(Self.trimmed(carbs))\u{00A0}g",
            comment: "iPhone approval: the carbs in grams. The no-break space keeps the number with its unit."
        )
    }

    /// "10 g fat · 12 g protein", or `nil` when there's neither.
    var fatAndProteinText: String? {
        var parts: [String] = []
        if let grams = Self.positive(fat) {
            parts.append(String(
                localized: "\(grams)\u{00A0}g fat",
                comment: "iPhone approval: the fat in grams. The no-break space keeps the number with its unit."
            ))
        }
        if let grams = Self.positive(protein) {
            parts.append(String(
                localized: "\(grams)\u{00A0}g protein",
                comment: "iPhone approval: the protein in grams. The no-break space keeps the number with its unit."
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver says for the dose, with the unit spelled out: "Insulin, 2.10 units".
    var spokenInsulin: String {
        String(
            localized: "Insulin, \(units) units",
            comment: "VoiceOver: the dose on the iPhone approval sheet, with the dose as shown, for example '2.10'."
        )
    }

    /// What VoiceOver says for the carbs, without trailing zeros: "Carbs, 35 grams".
    var spokenCarbs: String {
        let grams = Self.trimmed(carbs)
        if Self.amount(carbs) == 1 {
            return String(
                localized: "Carbs, \(grams) gram",
                comment: "VoiceOver: one gram of carbs on the iPhone approval sheet."
            )
        }
        return String(
            localized: "Carbs, \(grams) grams",
            comment: "VoiceOver: the carbs on the iPhone approval sheet, for example '35' grams."
        )
    }

    /// The amounts are strings with a `.` separator, whatever the wearer's locale.
    private static func amount(_ shown: String) -> Decimal? {
        Decimal(string: shown, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The amount without trailing zeros: "35.00" is "35", "12.50" is "12.5".
    private static func trimmed(_ shown: String) -> String {
        amount(shown)?.description ?? shown
    }

    /// The amount without trailing zeros when it's above 0, otherwise `nil`.
    private static func positive(_ shown: String) -> String? {
        guard let value = amount(shown), value > 0 else { return nil }
        return value.description
    }
}
