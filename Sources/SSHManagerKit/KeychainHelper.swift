import Foundation
import Security

/// macOS Keychain üzerinde sunucu parolalarını saklayan yardımcı.
/// Parolalar `kSecClassGenericPassword` olarak, servis adı sabit,
/// hesap adı ise sunucunun UUID'si ile saklanır.
public enum KeychainHelper {
    /// Eski sürümle aynı servis adı: kayıtlı parolalar olduğu gibi kullanılmaya devam eder.
    public static let service = "com.yusuf.sshmanager"

    /// Parolayı kaydeder veya günceller.
    @discardableResult
    public static func savePassword(_ password: String, account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound {
            // Güncellenemiyorsa (ör. eski erişim kuralı) silip yeniden ekle.
            deletePassword(account: account)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SSHManager"
        // Cihaz kilidi açıldıktan sonra erişilebilir, başka cihaza taşınmaz.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Parolayı okur. Yoksa nil döner.
    public static func readPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
    public static func deletePassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Parolanın kayıtlı olup olmadığına bakar. Parolanın kendisini okumaz;
    /// bu yüzden macOS "Anahtar Zinciri erişimi" izni sormaz.
    public static func hasPassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}
