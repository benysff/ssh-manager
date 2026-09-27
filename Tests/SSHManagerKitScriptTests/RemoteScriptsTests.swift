import Foundation
import Testing
@testable import SSHManagerKit

/// #expect yerine: makro açılımı gerektirmez (Komut Satırı Araçları'nda makro eklentisi sorun çıkarabiliyor),
/// hatayı yine doğru satırla bildirir.
func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "",
           fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) rethrows {
    if try !condition() {
        Issue.record(Comment(rawValue: message.isEmpty ? "Beklenti sağlanmadı" : message),
                     sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }
}

/// Birden çok küçük testi tek @Test içinde, kendi kapsamlarıyla çalıştırmak için.
private func parca(_ body: () throws -> Void) rethrows { try body() }

struct RemoteScriptsTests {
    /// Sağlık çıktısı okuma, değerlendirme ve "ulaşılamıyor" ile "giriş izni yok" ayrımı.
    @Test func testHealth() throws {
        try parca { // testParseAndVisibleOutput
            let out = "hello\nBD_A=1\nBD_PKG=curl\nBD_PKG=openssl\nworld\n"
            let kv = RemoteScripts.parse(out)
            check(kv["A"] == ["1"])
            check(kv["PKG"] == ["curl", "openssl"])
            check(RemoteScripts.visibleOutput(out) == "hello\nworld")
        }


        try parca { // testHealthReportHealthy
            let out = """
            BD_OK=1
            BD_OS=Ubuntu 24.04.1 LTS
            BD_UPTIME=86400
            BD_LOAD=0.42
            BD_CPUS=4
            BD_MEM=37
            BD_DISK=41
            BD_DISK_MOUNT=/
            BD_REBOOT=0
            BD_UPDATES=0
            BD_SECURITY=0
            BD_FAILED=0
            """
            let r = HealthReport.from(output: out)
            check(r.reachable)
            check(r.os == "Ubuntu 24.04.1 LTS")
            check(r.disk == 41)
            check(r.load == 0.42)
            check(r.evaluation.level == .ok)
            check(r.evaluation.issues.isEmpty)
        }


        try parca { // testHealthReportProblems
            let out = "BD_OK=1\nBD_DISK=93\nBD_DISK_MOUNT=/var\nBD_FAILED=2\nBD_SECURITY=5\nBD_UPDATES=12\nBD_REBOOT=1\nBD_LOAD=9.5\nBD_CPUS=2\nBD_MEM=97\n"
            let ev = HealthReport.from(output: out).evaluation
            check(ev.level == .bad)
            check(ev.issues.first == "Disk %93 dolu (/var)")
            check(ev.issues.contains("2 servis çökmüş"))
            check(ev.issues.contains("5 güvenlik güncellemesi bekliyor"))
            check(ev.issues.contains("Yeniden başlatma bekliyor"))
            check(ev.issues.contains("Bellek %97 dolu"))
            let warnOnly = HealthReport.from(output: "BD_OK=1\nBD_DISK=85\nBD_DISK_MOUNT=/\n").evaluation
            check(warnOnly.level == .warn)
        }


        try parca { // testFailureClassification
            let auth = HealthReport.failure(output: "deploy@1.2.3.4: Permission denied (publickey,password).")
            check(auth.errorKind == "auth")
            check(auth.evaluation.level == .unknown)
            let hostkey = HealthReport.failure(output: "Host key verification failed.")
            check(hostkey.errorKind == "hostkey")
            check(hostkey.evaluation.level == .unknown)
            let down = HealthReport.failure(output: "ssh: connect to host 1.2.3.4 port 22: Operation timed out")
            check(down.errorKind == "network")
            check(down.evaluation.level == .bad)
            check(HealthReport.from(output: "garbage").reachable == false)
        }

    }

    /// Güncelleme kontrolü, sudo sarmalayıcısı ve güncelleme betikleri.
    @Test func testUpdatesAndSudo() throws {
        try parca { // testUpdateCheckParse
            let out = "Hit:1 http://archive.ubuntu.com noble InRelease\nBD_TOTAL=3\nBD_SECURITY=1\nBD_REBOOT=1\nBD_UNATTENDED=1\nBD_PKG=curl\nBD_PKG=openssl\nBD_PKG=libc6\n"
            let c = UpdateCheck.from(output: out)
            check(c.supported)
            check(c.total == 3)
            check(c.security == 1)
            check(c.rebootRequired)
            check(c.hasUnattended)
            check(c.packages == ["curl", "openssl", "libc6"])
            check(UpdateCheck.from(output: "BD_UNSUPPORTED=1").supported == false)
        }


        try parca { // testAsRootWrapper
            let cmd = RemoteScripts.asRoot("echo 'merhaba'; id -u")
            check(cmd.hasPrefix("sh -c "))
            check(cmd.contains("sudo -n true"))
            check(cmd.contains("sudo -S -p "))  // boş istem, kabuk tırnaklamasıyla değişik görünür
            check(cmd.hasSuffix(SSHCommand.shellQuote("echo 'merhaba'; id -u")))
            check(RemoteScripts.sudoPasswordRejected("sudo: 1 incorrect password attempt"))
            check(RemoteScripts.sudoPasswordRejected("sudo: a password is required"))
            check(!RemoteScripts.sudoPasswordRejected("Reading package lists... Done"))
        }


        try parca { // testUpdateApplyScripts
            check(RemoteScripts.updateApply(securityOnly: false).contains("apt-get -y -q"))
            check(RemoteScripts.updateApply(securityOnly: false).contains("NEEDRESTART_MODE=l"))
            check(RemoteScripts.updateApply(securityOnly: true).contains("unattended-upgrade -v"))
        }

    }

    /// Kendi komutların kaydedilmesi ve hazır komutların güvenli varsayılanları.
    @Test func testSnippets() throws {
        try parca { // testStoreSaveAndRemove
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            let store = SnippetStore(fileURL: file)
            check(store.custom.isEmpty)
            check(store.all.count == Snippet.builtins.count)
            try store.save(Snippet(name: "Uygulamayı yeniden başlat", command: "systemctl restart app", asRoot: true, changesSystem: true))
            let reloaded = SnippetStore(fileURL: file)
            check(reloaded.custom.count == 1)
            check(reloaded.custom[0].asRoot)
            check(reloaded.custom[0].builtin == false)
            try reloaded.remove(id: reloaded.custom[0].id)
            check(SnippetStore(fileURL: file).custom.isEmpty)
        }


        try parca { // testBuiltinsAreSafeByDefault
            let ids = Set(Snippet.builtins.map(\.id))
            check(ids.count == Snippet.builtins.count)
            check(Snippet.builtins.filter(\.changesSystem).allSatisfy(\.asRoot))
        }

    }
}
