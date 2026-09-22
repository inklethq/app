import Foundation
import os
import Security

struct AuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

/// Where the session credentials live between launches.
///
/// Developer ID-signed release builds use the Keychain and nothing else — the
/// privacy policy says so. If a Keychain write fails, the session lives only
/// in `InkletAPI`'s memory for this launch and the next launch asks for a
/// sign-in; the failure is logged, never papered over with a file.
///
/// Ad-hoc local builds use a 0600 file instead, because their identity changes
/// on every rebuild and would otherwise trigger a modal Keychain authorization
/// prompt at launch.
enum TokenStore {
    // CI defines INKLET_RELEASE only for the Developer ID-signed build. Local
    // ad-hoc builds deliberately keep using the 0600 file so every rebuild does
    // not look like a new app asking to access an older keychain item.
    #if INKLET_RELEASE
    private static let usesKeychain = true
    #else
    private static let usesKeychain = false
    #endif

    private static let service = "com.iminklet.mac"
    private static let account = "session"
    /// Statuses only. Nothing here ever logs a token.
    private static let log = Logger(subsystem: "com.iminklet.mac", category: "session")

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inklet", isDirectory: true)
    }

    /// The ad-hoc build's store — and, in a release build, only ever the
    /// leftover that release builds before this one wrote when the Keychain
    /// refused a write.
    private static var fileURL: URL { directory.appendingPathComponent("session.json") }

    static func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }

        guard usesKeychain else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return
        }

        let status = keychainSave(data)
        if status != errSecSuccess {
            log.error("Keychain refused the session (OSStatus \(status, privacy: .public)); it is kept in memory for this launch only")
        }
        // Whatever the Keychain said, a release build leaves no plaintext copy.
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Blocking. Never call this from the main thread — see `usesKeychain`.
    ///
    /// Ad-hoc builds have no migration path from the Keychain on purpose:
    /// reading an item another build wrote is what raises the authorization
    /// dialog, and there is no way to try it without risking a launch that sits
    /// on a spinner waiting for a click. One re-login is cheaper than that.
    static func load() -> AuthTokens? {
        guard usesKeychain else {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(AuthTokens.self, from: data)
        }
        if let data = keychainLoad(), let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data) {
            try? FileManager.default.removeItem(at: fileURL)
            return tokens
        }
        return migrateLegacyFile()
    }

    /// Earlier release builds wrote the session to a plaintext file when the
    /// Keychain refused it. Such a session moves into the Keychain, and the
    /// file goes whether or not the move worked: if it didn't, the session
    /// still serves this launch from memory, like any failed write.
    private static func migrateLegacyFile() -> AuthTokens? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        log.notice("Moving a session file left by an earlier release into the Keychain")
        save(tokens)
        return tokens
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

    private static func keychainSave(_ data: Data) -> OSStatus {
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func keychainLoad() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                log.error("Keychain read failed (OSStatus \(status, privacy: .public))")
            }
            return nil
        }
        return result as? Data
    }
}
