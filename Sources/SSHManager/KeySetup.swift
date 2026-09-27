import Foundation
import SSHManagerKit

/// "Parolasız girişe geç": SSH anahtarını sunucuya yükler ve çalıştığını doğrular.
/// Kayıtlı parola yalnızca bu yükleme için bir kez kullanılır.
enum KeySetup {

    struct Plan {
        let privateKey: String
        let publicKey: String
        let willGenerate: Bool
    }

    /// Hangi anahtarın kullanılacağı: sunucuya tanımlı anahtar varsa o, yoksa ~/.ssh/id_ed25519.
    static func plan(for server: Server) -> Plan {
        let priv = server.identityFile.isEmpty
            ? Paths.expandTilde("~/.ssh/id_ed25519")
            : Paths.expandTilde(server.identityFile)
        let pub = priv + ".pub"
        let fm = FileManager.default
        return Plan(privateKey: priv, publicKey: pub,
                    willGenerate: !fm.fileExists(atPath: priv) && !fm.fileExists(atPath: pub))
    }

    /// Arka planda çalışır; bitince ana iş parçacığında sonuç döner.
    static func run(for server: Server, completion: @escaping (Result<Server, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try perform(server) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func perform(_ server: Server) throws -> Server {
        let p = plan(for: server)
        let fm = FileManager.default

        if p.willGenerate {
            try fm.createDirectory(atPath: (p.privateKey as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let (code, out) = runProcess("/usr/bin/ssh-keygen",
                                         ["-t", "ed25519", "-N", "", "-C", "\(NSUserName())@sshmanager", "-f", p.privateKey])
            guard code == 0 else { throw SSHManagerError.failed("Anahtar oluşturulamadı:\n\(out)") }
        } else if !fm.fileExists(atPath: p.publicKey) {
            throw SSHManagerError.failed("\(p.publicKey) bulunamadı. Anahtarın açık (.pub) kısmı gerekli.")
        }

        // Anahtarı sunucuya yükle. ssh-copy-id kendi içinde ssh çağırır; parolayı askpass verir.
        let env = SSHCommand.askpassEnvironment(helper: AppPaths.executable, serverID: server.id)
        let (copyCode, copyOut) = runProcess("/usr/bin/ssh-copy-id",
                                             ["-i", p.publicKey, "-p", String(server.port),
                                              "-o", "ServerAliveInterval=30", server.sshDestination], env: env)
        guard copyCode == 0 else {
            throw SSHManagerError.failed("Anahtar sunucuya yüklenemedi:\n\(lastLines(copyOut))")
        }

        // Parola kullanmadan girebildiğimizi doğrula.
        let (testCode, testOut) = runProcess(SSHCommand.sshPath, [
            "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "ConnectTimeout=15", "-i", p.privateKey, "-p", String(server.port),
            "--", server.sshDestination, "true",
        ])
        guard testCode == 0 else {
            throw SSHManagerError.failed("Anahtar yüklendi ama parolasız giriş denemesi başarısız oldu. "
                                         + "Sunucuda anahtarla girişe izin verilmiyor olabilir.\n\(lastLines(testOut))")
        }

        var updated = server
        updated.identityFile = (p.privateKey as NSString).abbreviatingWithTildeInPath
        return updated
    }

    // MARK: - Yardımcılar

    @discardableResult
    static func runProcess(_ path: String, _ args: [String], env extra: [String: String] = [:]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func lastLines(_ text: String, _ n: Int = 6) -> String {
        text.split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}
