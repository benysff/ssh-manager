import Foundation
import Security

/// macOS Keychain üzerinde sunucu parolalarını saklayan yardımcı.
///
/// Bütün parolalar tek bir Anahtar Zinciri kaydında ("kasa") JSON olarak durur. macOS erişim iznini kayıt başına
/// sorduğu için, sunucu başına ayrı kayıt olsaydı 100 sunucuda 100 kez izin (ve Mac parolası) istenirdi;
/// kasa ile uygulama başına bir kez sorulur.
///
/// Eski sürümlerin sunucu başına kayıtları (hesap adı = sunucu UUID'si) okunmaya devam eder ve ilk okunuşta kasaya taşınır.
public enum KeychainHelper {
    /// Eski sürümle aynı servis adı. Testler kendi kayıtlarını ayırmak için `SSHMANAGER_KEYCHAIN_SERVICE` verebilir.
    public static let service = ProcessInfo.processInfo.environment["SSHMANAGER_KEYCHAIN_SERVICE"] ?? "com.yusuf.sshmanager"
    /// Kasanın hesap adı. Sunucu hesapları UUID olduğundan çakışmaz.
    static let vaultAccount = "kasa"

    // MARK: - Genel arayüz

    /// Parolayı kaydeder veya günceller.
    @discardableResult
    public static func savePassword(_ password: String, account: String) -> Bool {
        guard var vault = openVaultForWriting() else {
            // Kasa var ama okunamıyor (izin verilmedi): üzerine yazıp içindekileri kaybetmek yerine eski usul kaydet.
            return saveItem(Data(password.utf8), account: account, generic: nil)
        }
        vault[account] = password
        guard writeVault(vault) else { return false }
        deleteLegacy(account: account)
        return true
    }

    /// Parolayı okur. Yoksa nil döner.
    /// `allowUI: false` ise macOS'un "Anahtar Zinciri'ne erişim izni" penceresi hiç açılmaz; izin gerekiyorsa nil döner
    /// (arka plandaki sağlık kontrolleri kullanıcıyı pencerelerle rahatsız etmesin diye).
    public static func readPassword(account: String, allowUI: Bool = true) -> String? {
        let vault = loadVault(allowUI: allowUI)
        if let password = vault?[account] { return password }
        guard let data = readItem(account: account, allowUI: allowUI),
              let password = String(data: data, encoding: .utf8) else { return nil }
        // Eski tek kayıt: kasa okunabiliyorsa oraya taşı (bir daha ayrıca izin sorulmasın).
        if var vault = vault {
            vault[account] = password
            if writeVault(vault) { deleteLegacy(account: account) }
        }
        return password
    }

    /// Parolayı siler.
    @discardableResult
    public static func deletePassword(account: String) -> Bool {
        var ok = true
        if index().contains(account) {
            if var vault = loadVault(allowUI: true) {
                vault[account] = nil
                ok = writeVault(vault)
            } else {
                ok = false
            }
        }
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        return ok && (status == errSecSuccess || status == errSecItemNotFound)
    }

    /// Parolanın kayıtlı olup olmadığına bakar. Parolanın kendisini okumaz;
    /// bu yüzden macOS "Anahtar Zinciri erişimi" izni sormaz.
    public static func hasPassword(account: String) -> Bool {
        index().contains(account) || legacyAccounts().contains(account)
    }

    // MARK: - Kasa durumu

    /// Kasanın kilidini açar (gerekirse macOS bir kez izin sorar) ve verilen hesapların eski tek kayıtlarını kasaya taşır.
    /// Eski kayıtların her biri, taşınırken son bir kez izin isteyebilir; sonrasında hep tek kayıt okunur.
    /// Kasa açılamadıysa false döner.
    @discardableResult
    public static func unlock(migrating accounts: [String]) -> Bool {
        guard var vault = openVaultForWriting() else { return false }
        var moved: [String] = []
        for account in pendingMigration(accounts, vault: vault).sorted() {
            guard let data = readItem(account: account, allowUI: true),
                  let password = String(data: data, encoding: .utf8) else { continue }
            vault[account] = password
            moved.append(account)
        }
        if !moved.isEmpty {
            guard writeVault(vault) else { return false }
        }
        moved.forEach(deleteLegacy)
        return true
    }

    /// Kasa bu süreçte izin sormadan okunabiliyor mu ve verilen hesaplardan taşınmayı bekleyen eski kayıt kalmadı mı?
    public static func isUnlocked(accounts: [String]) -> Bool {
        guard let vault = loadVault(allowUI: false) else { return false }
        return pendingMigration(accounts, vault: vault).isEmpty
    }

    /// Sadece testler için: test servis adındaki bütün kayıtları siler. Gerçek servis adında hiçbir şey yapmaz.
    @discardableResult
    public static func removeTestService() -> Bool {
        guard service != "com.yusuf.sshmanager" else { return false }
        cache = nil
        let status = withInteraction(false) {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Eski tek kaydı olup kasada henüz olmayan hesaplar.
    private static func pendingMigration(_ accounts: [String], vault: [String: String]) -> Set<String> {
        legacyAccounts().intersection(accounts).subtracting(vault.keys)
    }

    // MARK: - Kasa

    private struct Index: Codable {
        var revision: String
        var accounts: [String]
    }

    /// Bu süreçte bir kez okunan kasa; kasa değişmedikçe (başka süreç yazmadıkça) tekrar okunmaz, izin tekrar sorulmaz.
    private static var cache: (revision: String, passwords: [String: String])?

    /// Kasa kaydının şifresiz öznitelikleri: hangi hesaplar var ve kasa en son ne zaman yazıldı.
    /// Parolaları çözmediği için izin penceresi açmaz.
    private static func readIndex() -> Index? {
        var query = itemQuery(account: vaultAccount)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any],
              let generic = attrs[kSecAttrGeneric as String] as? Data else { return nil }
        return try? JSONDecoder().decode(Index.self, from: generic)
    }

    private static func vaultExists() -> Bool {
        var query = itemQuery(account: vaultAccount)
        query[kSecReturnAttributes as String] = true
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func index() -> Set<String> {
        Set(readIndex()?.accounts ?? [])
    }

    /// Kasayı okur. Kasa henüz yoksa boş sözlük; var ama okunamıyorsa (izin yok ya da reddedildi) nil.
    private static func loadVault(allowUI: Bool) -> [String: String]? {
        guard vaultExists() else { return [:] }
        let revision = readIndex()?.revision ?? ""
        if let cache = cache, cache.revision == revision { return cache.passwords }
        guard let data = readItem(account: vaultAccount, allowUI: allowUI),
              let passwords = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        cache = (revision, passwords)
        return passwords
    }

    /// Yazmadan önce kasanın en güncel hali (başka bir süreç bu arada parola kaydetmiş olabilir).
    private static func openVaultForWriting() -> [String: String]? {
        cache = nil
        return loadVault(allowUI: true)
    }

    private static func writeVault(_ passwords: [String: String]) -> Bool {
        let index = Index(revision: UUID().uuidString, accounts: passwords.keys.sorted())
        guard let data = try? JSONEncoder().encode(passwords),
              let generic = try? JSONEncoder().encode(index),
              saveItem(data, account: vaultAccount, generic: generic) else { return false }
        cache = (index.revision, passwords)
        return true
    }

    // MARK: - Tek kayıtlar

    private static func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// (internal: testler eski usul tek kayıt oluşturabilsin diye)
    static func saveItem(_ data: Data, account: String, generic: Data?) -> Bool {
        let query = itemQuery(account: account)
        var update: [String: Any] = [kSecValueData as String: data]
        if let generic = generic { update[kSecAttrGeneric as String] = generic }
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound {
            // Güncellenemiyorsa (ör. eski erişim kuralı) silip yeniden ekle.
            SecItemDelete(query as CFDictionary)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SSHManager"
        if let generic = generic { add[kSecAttrGeneric as String] = generic }
        // Cihaz kilidi açıldıktan sonra erişilebilir, başka cihaza taşınmaz.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func readItem(account: String, allowUI: Bool) -> Data? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = withInteraction(allowUI) { SecItemCopyMatching(query as CFDictionary, &result) }
        return status == errSecSuccess ? result as? Data : nil
    }

    /// Eski sürümden kalan, sunucu başına tek kayıtların hesap adları (parolaları okumaz, izin sormaz).
    static func legacyAccounts() -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != vaultAccount })
    }

    /// Taşınan eski kaydı sessizce siler. Başka bir derlemeye aitse macOS izin isteyeceği için dokunmaz;
    /// kasa her zaman önce okunduğundan kalması zararsızdır.
    private static func deleteLegacy(account: String) {
        _ = withInteraction(false) { SecItemDelete(itemQuery(account: account) as CFDictionary) }
    }

    /// `allowUI: false` iken bu süreçte her türlü Anahtar Zinciri penceresini kapatır; izin gerekiyorsa pencere yerine
    /// hemen hata döner. (kSecUseAuthenticationUIFail dosya tabanlı Anahtar Zinciri'nde pencereyi engellemiyor,
    /// macOS 27'de takılabiliyor.)
    private static func withInteraction(_ allowUI: Bool, _ body: () -> OSStatus) -> OSStatus {
        guard !allowUI else { return body() }
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }
}
