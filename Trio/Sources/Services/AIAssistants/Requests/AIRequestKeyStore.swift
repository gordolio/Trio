import Foundation
import Security

/// The key the phone shares with the watch to sign the watch's answers. The watch asks for a key, and the
/// phone makes a new one each time.
final class AIRequestKeyStore {
    private static let account = "answer-key"

    private let keychain: AIRequestKeychain

    init(keychain: AIRequestKeychain = SystemAIRequestKeychain()) {
        self.keychain = keychain
    }

    var current: Data? {
        keychain.data(for: Self.account)
    }

    /// Makes a new 256-bit key, stores it in place of the old one, and returns it. Returns `nil` if the key
    /// couldn't be stored, and the old key stays.
    func rotate() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Never sign with the zeroed buffer. The system generator is a CSPRNG on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        let key = Data(bytes)
        guard keychain.set(key, for: Self.account) else {
            debug(.service, "AI requests: couldn't store a new answer key")
            return nil
        }
        return key
    }
}
