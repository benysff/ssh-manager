import Foundation
import Security
import Testing
@testable import SSHManagerKit

/// Tek kayıtlık parola kasası ve askpass'a parola veren boru.
struct VaultTests {
    /// Parola boruya bir kez yazılır, bir kez okunur; sonra boru yok olur.
    @Test func testPasswordPipe() throws {
        let dir = FileManager.default.temporaryDirectory.path
        let pipe = try #require(PasswordPipe(password: "gizli şifre 123", directory: dir))
        check(FileManager.default.fileExists(atPath: pipe.path))
        check(PasswordPipe.take(path: pipe.path) == "gizli şifre 123")
        check(!FileManager.default.fileExists(atPath: pipe.path), "okununca silinmeli")
        check(PasswordPipe.take(path: pipe.path) == nil, "ikinci deneme parolayı alamamalı")
        pipe.close()

        // Okunmadan kapatılırsa da iz kalmaz.
        let unused = try #require(PasswordPipe(password: "x", directory: dir))
        unused.close()
        check(!FileManager.default.fileExists(atPath: unused.path))

        // Ortam değişkeniyle normal bir dosya verilirse ne okunur ne silinir.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "dokunma\n".write(to: file, atomically: true, encoding: .utf8)
        check(PasswordPipe.take(path: file.path) == nil)
        check(FileManager.default.fileExists(atPath: file.path), "FIFO olmayan dosya silinmemeli")
        try? FileManager.default.removeItem(at: file)
    }

    /// Eski tek kayıtlar kasaya taşınır; kasa tek kayıttır; silme ve "var mı" izin sormadan çalışır.
    /// Kendi test servis adını kullanır (gerçek parolalara dokunmaz). Anahtar Zinciri kilitliyse atlanır.
    @Test func testVault() throws {
        let service = "com.yusuf.sshmanager.test-\(UUID().uuidString)"
        setenv("SSHMANAGER_KEYCHAIN_SERVICE", service, 1)
        guard KeychainHelper.service == service else {
            Issue.record("KeychainHelper.service test servisine ayarlanamadı")
            return
        }
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString

        // Eski sürümün yazdığı gibi sunucu başına kayıt.
        guard KeychainHelper.saveItem(Data("parola-a".utf8), account: a, generic: nil) else { return }
        check(KeychainHelper.hasPassword(account: a))
        check(KeychainHelper.legacyAccounts() == [a])

        // İlk okuma kasaya taşır ve eski kaydı kaldırır.
        check(KeychainHelper.readPassword(account: a, allowUI: false) == "parola-a")
        check(KeychainHelper.index() == [a])
        check(KeychainHelper.legacyAccounts().isEmpty, "taşınan eski kayıt silinmeli")

        // Yeni parolalar doğrudan kasaya.
        check(KeychainHelper.savePassword("parola-b", account: b))
        check(KeychainHelper.readPassword(account: b, allowUI: false) == "parola-b")
        check(KeychainHelper.index() == [a, b])
        check(KeychainHelper.legacyAccounts().isEmpty)
        check(KeychainHelper.savePassword("parola-b2", account: b))
        check(KeychainHelper.readPassword(account: b, allowUI: false) == "parola-b2")

        // Toplu kilit açma: istenen hesapların eski kayıtları bir seferde taşınır.
        check(KeychainHelper.saveItem(Data("parola-c".utf8), account: c, generic: nil))
        check(!KeychainHelper.isUnlocked(accounts: [a, b, c]), "taşınmayı bekleyen kayıt varken kilitli sayılmalı")
        check(KeychainHelper.isUnlocked(accounts: [a, b]), "ilgisiz eski kayıtlar kilidi etkilememeli")
        check(KeychainHelper.unlock(migrating: [a, b, c]))
        check(KeychainHelper.isUnlocked(accounts: [a, b, c]))
        check(KeychainHelper.index() == [a, b, c])
        check(KeychainHelper.readPassword(account: c, allowUI: false) == "parola-c")

        // Silme.
        check(KeychainHelper.deletePassword(account: a))
        check(!KeychainHelper.hasPassword(account: a))
        check(KeychainHelper.readPassword(account: a, allowUI: false) == nil)
        check(KeychainHelper.readPassword(account: b, allowUI: false) == "parola-b2", "diğerleri yerinde kalmalı")
        check(KeychainHelper.deletePassword(account: UUID().uuidString), "olmayanı silmek hata değil")
    }
}
