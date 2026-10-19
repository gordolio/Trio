import Foundation

/// The service address, `trio-ios` tokens, signed-in account and last registered device, kept in
/// the Keychain.
final class AIAssistantsTokenStore {
    enum Key {
        static let baseURL = "AIAssistants.baseURL"
        static let tokens = "AIAssistants.tokens"
        static let lastDevice = "AIAssistants.lastDevice"
        static let account = "AIAssistants.account"
    }

    private let keychain: Keychain

    init(keychain: Keychain) {
        self.keychain = keychain
    }

    /// The app's store. Items stay on this device (never in iCloud Keychain, never restored onto
    /// another phone) and stay readable while the phone is locked, for background loops.
    static func deviceOnly(serviceName: String = Bundle.main.bundleIdentifier ?? "SwiftBaseKeychain") -> AIAssistantsTokenStore {
        AIAssistantsTokenStore(
            keychain: BaseKeychain(
                serviceName: serviceName,
                synchronizable: false,
                accessibilityLevel: .afterFirstUnlockThisDeviceOnly
            )
        )
    }

    var baseURL: URL? {
        get {
            let value = try? (keychain.getValue(String.self, forKey: Key.baseURL) as Result<String?, KeychainError>).get()
            return value.flatMap { URL(string: $0) }
        }
        set { _ = keychain.setValue(newValue?.absoluteString, forKey: Key.baseURL) as Result<Void, KeychainError> }
    }

    /// Setting `nil` removes the key.
    var tokens: AIAssistantsTokens? {
        get {
            try? (keychain.getValue(AIAssistantsTokens.self, forKey: Key.tokens) as Result<AIAssistantsTokens?, KeychainError>)
                .get()
        }
        set { _ = keychain.setValue(newValue, forKey: Key.tokens) as Result<Void, KeychainError> }
    }

    /// The device last sent with `PUT /api/v1/device`. Setting `nil` removes the key.
    var lastDevice: DeviceRegistration? {
        get {
            try? (
                keychain
                    .getValue(DeviceRegistration.self, forKey: Key.lastDevice) as Result<DeviceRegistration?, KeychainError>
            )
            .get()
        }
        set { _ = keychain.setValue(newValue, forKey: Key.lastDevice) as Result<Void, KeychainError> }
    }

    /// Who Trio signed in as. Links made before Trio kept it have none. Setting `nil` removes the key.
    var account: AIAssistantsAccount? {
        get {
            try? (keychain.getValue(AIAssistantsAccount.self, forKey: Key.account) as Result<AIAssistantsAccount?, KeychainError>)
                .get()
        }
        set { _ = keychain.setValue(newValue, forKey: Key.account) as Result<Void, KeychainError> }
    }

    func clear() {
        for key in [Key.baseURL, Key.tokens, Key.lastDevice, Key.account] {
            keychain.removeObject(forKey: key)
        }
    }
}
