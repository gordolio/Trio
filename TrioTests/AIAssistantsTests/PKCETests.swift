import Foundation
import Testing

@testable import Trio

@Suite("AI Assistants PKCE and Apple nonce") struct PKCETests {
    @Test("Challenge matches the RFC 7636 example") func challengeMatchesRFC7636Vector() {
        #expect(
            PKCE
                .challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("Generated verifier is 64 base64url characters and matches its challenge") func generatedVerifier() {
        let pkce = PKCE.generate()
        #expect(pkce.verifier.count == 64)
        #expect(pkce.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(pkce.challenge == PKCE.challenge(for: pkce.verifier))
        #expect(PKCE.generate().verifier != pkce.verifier)
    }

    @Test("Apple nonce hash is lowercase SHA-256 hex of the raw nonce") func appleNonceHashIsSHA256Hex() {
        #expect(AppleNonce.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let nonce = AppleNonce.generate()
        #expect(nonce.raw.count == 43)
        #expect(nonce.hashed == AppleNonce.sha256Hex(nonce.raw))
        #expect(AppleNonce.generate().raw != nonce.raw)
    }
}
