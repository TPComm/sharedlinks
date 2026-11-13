import CryptoKit
import Foundation
import Security

/// One sign-in attempt's PKCE values (RFC 7636). The verifier never leaves the device
/// until the code exchange, so an intercepted authorization code is useless on its own.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        verifier = Self.randomString(bytes: 32)
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        state = Self.randomString(bytes: 16)
    }

    static func randomString(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(status == errSecSuccess, "No secure random bytes available")
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The Links session token lives in the keychain under the App Group's access group, so the
/// app, the Share Extension and the widget all read the same one. It's a long-lived server
/// session (not a rotating WorkOS refresh token), so the three processes never race.
public enum SessionStore {
    static let service = "links.session"
    static let account = "token"
    static let userKey = "links.currentUser"

    public static var token: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static var isSignedIn: Bool { token != nil }

    @discardableResult
    public static func save(token: String, user: LinkUser? = nil) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // Widgets refresh while the phone is locked, so allow reads after first unlock.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if let user { currentUser = user }
        return status == errSecSuccess
    }

    public static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        LinksConfig.sharedDefaults.removeObject(forKey: userKey)
    }

    /// Who's signed in, for extensions that want a name without a network call.
    public static var currentUser: LinkUser? {
        get {
            LinksConfig.sharedDefaults.data(forKey: userKey)
                .flatMap { try? APIClient.decoder.decode(LinkUser.self, from: $0) }
        }
        set {
            let data = newValue.flatMap { try? APIClient.encoder.encode($0) }
            LinksConfig.sharedDefaults.set(data, forKey: userKey)
        }
    }

    static var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // On iOS an App Group identifier doubles as a keychain access group.
        if let group = LinksConfig.appGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}
