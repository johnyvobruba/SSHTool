import Foundation
import Security
import LocalAuthentication

/// Hesla v login Keychainu (generic password), account = UUID session.
/// ssh volá jako SSH_ASKPASS tutéž (stejně podepsanou) binárku, takže ji Keychain pustí bez dalšího dotazu.
///
/// Příznak „vyžadovat ověření uživatele“ je uložen přímo v položce Keychainu (kSecAttrComment),
/// ne v sessions.json – soubor může kdokoli s právy uživatele přepsat, položku Keychainu bez
/// přístupu k ní upravit nejde.
enum KeychainStore {
    static let service = "cz.local.sshtool"
    private static let requireAuthMarker = "sshtool:require-user-auth"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func setPassword(_ password: String, for account: String, requireAuth: Bool) throws {
        let data = Data(password.utf8)
        let comment = requireAuth ? requireAuthMarker : ""
        let status = SecItemUpdate(base(account) as CFDictionary,
                                   [kSecValueData as String: data,
                                    kSecAttrComment as String: comment] as CFDictionary)
        if status == errSecItemNotFound {
            var q = base(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "SSHTool"
            q[kSecAttrComment as String] = comment
            let add = SecItemAdd(q as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Změní jen příznak ověření (heslo zůstává).
    static func setRequireAuth(_ requireAuth: Bool, for account: String) throws {
        let status = SecItemUpdate(base(account) as CFDictionary,
                                   [kSecAttrComment as String: requireAuth ? requireAuthMarker : ""] as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Čte jen atributy (ne heslo) – zjistí, zda je před vydáním hesla potřeba Touch ID / heslo Macu.
    static func requiresAuth(for account: String) -> Bool {
        var q = base(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any] else { return false }
        return (attrs[kSecAttrComment as String] as? String) == requireAuthMarker
    }

    static func password(for account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)" }
}

/// Ověření vlastníka Macu: Touch ID, případně heslo uživatele macOS (systémový dialog).
enum UserAuth {
    private final class Result: @unchecked Sendable { var ok = false }

    /// Synchronní – volat mimo hlavní vlákno UI nebo v askpass procesu. Při chybě/zrušení false (fail-closed).
    static func authenticate(reason: String) -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            result.ok = success
            done.signal()
        }
        done.wait()
        return result.ok
    }
}
