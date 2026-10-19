import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange (RFC 7636), S256 method.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    /// The verifier is 64 base64url characters (48 random bytes).
    static func generate() -> PKCE {
        let verifier = SecureRandom.base64URL(byteCount: 48)
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

enum SecureRandom {
    static func bytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    static func base64URL(byteCount: Int) -> String {
        bytes(byteCount).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
