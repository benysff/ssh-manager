import Foundation
import Security

/// macOS Keychain üzerinde sunucu parolalarını saklayan yardımcı.
/// Parolalar `kSecClassGenericPassword` olarak, servis adı sabit,
/// hesap adı ise sunucunun UUID'si ile saklanır.
enum KeychainHelper {
    private static let service = "com.yusuf.sshmanager"

    /// Parolayı kaydeder veya günceller.
    @discardableResult
    static func savePassword(_ password: String, account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // Önce var olanı sil, sonra ekle (basit upsert).
        deletePassword(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Cihaz kilidi açıldıktan sonra erişilebilir, başka cihaza taşınmaz.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Parolayı okur. Yoksa nil döner.
    static func readPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// Parolayı siler.
    @discardableResult
    static func deletePassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func hasPassword(account: String) -> Bool {
        readPassword(account: account) != nil
    }
}
