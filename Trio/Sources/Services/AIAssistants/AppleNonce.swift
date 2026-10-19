import CryptoKit
import Foundation

/// The nonce for Sign in with Apple. Apple gets `hashed` and puts it in the identity
/// token; the service gets `raw` and checks that it hashes to the token's nonce.
struct AppleNonce: Equatable {
    let raw: String
    let hashed: String

    static func generate() -> AppleNonce {
        let raw = SecureRandom.base64URL(byteCount: 32)
        return AppleNonce(raw: raw, hashed: sha256Hex(raw))
    }

    /// Lowercase hex SHA-256.
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
