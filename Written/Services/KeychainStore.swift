import Foundation
import Security

/// Minimal Keychain wrapper for persisting OAuth refresh tokens between launches,
/// so a returning user never has to re-consent (the "one button" stays one button).
enum KeychainStore {
    private static let service = "com.written.datingapp.tokens"

    /// The keychain group the app and the share extension both reach.
    ///
    /// The extension has to read the session to attribute a share to whoever is
    /// signed in, and an extension has its own bundle id and so its own default
    /// keychain group. Naming a shared one is the only way both can see the same
    /// item.
    ///
    /// The team prefix is not a secret — it is in every provisioning profile and
    /// on the App ID page — and it has to be a literal here because entitlements
    /// resolve `$(AppIdentifierPrefix)` at build time and code cannot.
    private static let accessGroup = "947DHTL37S.com.written.datingapp"

    /// Every existing item was written before there was a group, which put it in
    /// the app's default one — the same string as above, since that default *is*
    /// the app identifier. So naming it explicitly finds them and nobody is
    /// signed out by this change.
    ///
    /// `read` still falls back to a query without the group, because being wrong
    /// about that would drop the session of everyone who already has one, and a
    /// second query costs nothing on a path that runs a handful of times.
    private static func query(_ key: String, grouped: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if grouped { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func save(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query = self.query(key)
        SecItemDelete(query as CFDictionary)
        // The ungrouped copy too, or a legacy item survives beside the new one
        // and `read` can return whichever the keychain happens to hand back.
        SecItemDelete(self.query(key, grouped: false) as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        if let value = read(key, grouped: true) { return value }
        // Written before the group existed. Found, returned, and left alone —
        // migrating on read would mean writing from whichever process asked
        // first, including the share extension.
        return read(key, grouped: false)
    }

    private static func read(_ key: String, grouped: Bool) -> String? {
        var query = self.query(key, grouped: grouped)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        // Both copies. Signing out has to remove the item wherever it is, and a
        // legacy ungrouped one left behind would be found by the next `read`
        // and quietly restore the session.
        SecItemDelete(query(key) as CFDictionary)
        SecItemDelete(query(key, grouped: false) as CFDictionary)
    }
}
