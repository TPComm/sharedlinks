import CryptoKit
import Foundation
import Testing
@testable import LinksKit

@Suite("PKCE")
struct PKCETests {
    @Test func matchesTheRFC7636Example() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func challengeIsS256OfTheVerifier() {
        let pkce = PKCE()
        let digest = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
        #expect(Self.decodeBase64URL(pkce.challenge) == digest)
    }

    @Test func verifierIsUnreservedAndLongEnough() throws {
        // RFC 7636 §4.1: 43-128 characters from [A-Z a-z 0-9 - . _ ~]; 32 random bytes.
        let pkce = PKCE()
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for value in [pkce.verifier, pkce.challenge, pkce.state] {
            #expect(value.unicodeScalars.allSatisfy(unreserved.contains))
        }
        #expect((43...128).contains(pkce.verifier.count))
        #expect(try #require(Self.decodeBase64URL(pkce.verifier)).count == 32)
        #expect(try #require(Self.decodeBase64URL(pkce.state)).count == 16)
    }

    @Test func everyAttemptIsFresh() {
        let attempts = (0..<200).map { _ in PKCE() }
        #expect(Set(attempts.map(\.verifier)).count == 200)
        #expect(Set(attempts.map(\.state)).count == 200)
    }

    @Test func base64URLHasNoPaddingOrURLSpecialCharacters() {
        #expect(PKCE.base64URL(Data([0xFB, 0xFF, 0xBF])) == "-_-_")  // "+/+/" in plain base64
        #expect(PKCE.base64URL(Data([0xFF])) == "_w")  // "/w=="
        #expect(PKCE.base64URL(Data([0xFB, 0xEF])) == "--8")  // "++8="
        #expect(PKCE.base64URL(Data()) == "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

@Suite("Sign-in URL")
struct AuthorizeURLTests {
    let client = APIClient(baseURL: URL(string: "https://links.example.com")!, token: nil)

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func signInSendsChallengeAndState() {
        let pkce = PKCE()
        let url = client.authorizeURL(pkce: pkce)
        #expect(url.scheme == "https")
        #expect(url.host() == "links.example.com")
        #expect(url.path() == "/auth/authorize")
        // The verifier stays on the device until the code exchange.
        #expect(query(url) == ["code_challenge": pkce.challenge, "state": pkce.state])
        #expect(!url.absoluteString.contains(pkce.verifier))
    }

    @Test func signUpAsksForTheSignUpScreen() {
        let pkce = PKCE()
        #expect(query(client.authorizeURL(pkce: pkce, signUp: true)) ==
                ["code_challenge": pkce.challenge, "state": pkce.state, "screen_hint": "sign-up"])
    }

    @Test func keepsAPathPrefix() {
        let client = APIClient(baseURL: URL(string: "https://example.com/links/")!, token: nil)
        #expect(client.authorizeURL(pkce: PKCE()).path() == "/links/auth/authorize")
    }
}
