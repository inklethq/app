import Foundation
import Security

struct AuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

/// Where the session credentials live between launches.
///
/// Developer ID-signed release builds use Keychain. Ad-hoc local builds use a
/// 0600 fallback file because their identity changes on every rebuild and would
/// otherwise trigger a modal Keychain authorization prompt at launch. The first
/// successful release-build token write removes that fallback file.
enum TokenStore {
    // CI defines INKLET_RELEASE only for the Developer ID-signed build. Local
    // ad-hoc builds deliberately keep using the 0600 fallback file so every
    // rebuild does not look like a new app asking to access an older keychain
    // item. The public build always stores refresh credentials in Keychain.
    #if INKLET_RELEASE
    private static let usesKeychain = true
    #else
    private static let usesKeychain = false
    #endif

    private static let service = "com.iminklet.mac"
    private static let account = "session"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inklet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("session.json")
    }

    static func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }

        if usesKeychain, keychainSave(data) {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Blocking. Never call this from the main thread — see `usesKeychain`.
    ///
    /// No migration path from the Keychain-backed builds on purpose: reading that
    /// item is what raises the authorization dialog, and there is no way to try it
    /// without risking a launch that sits on a spinner waiting for a click. One
    /// re-login is cheaper than that, every time.
    static func load() -> AuthTokens? {
        if usesKeychain,
           let data = keychainLoad(),
           let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data) {
            return tokens
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    static func clear() {
        // Deleting doesn't read the secret, so it's safe to run unconditionally —
        // this also sweeps up the item left behind by the Keychain-backed builds.
        SecItemDelete(baseQuery() as CFDictionary)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainSave(_ data: Data) -> Bool {
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainLoad() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
