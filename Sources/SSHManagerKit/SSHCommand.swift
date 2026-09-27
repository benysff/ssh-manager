import Foundation

/// ssh komutlarını argüman dizisi olarak kurar. Hiçbir yerde kabuk (shell) üzerinden
/// birleştirme yapılmaz; böylece "bağlantı sonrası komut" yerelde değil, sunucuda çalışır.
public enum SSHCommand {
    public static let sshPath = "/usr/bin/ssh"

    /// ssh'ın parolayı bize sorması için kullanılan ortam değişkenleri.
    public enum Env {
        public static let askpassFlag = "SSHMANAGER_ASKPASS"
        public static let serverID = "SSHMANAGER_SERVER"
        public static let shimServerID = "SSHMANAGER_SHIM_SERVER"
        /// Arka plan işleri: askpass asla pencere açmaz, sadece kayıtlı parolayı (izin gerekmeden okunabiliyorsa) verir.
        public static let silent = "SSHMANAGER_ASKPASS_SILENT"
        /// Uygulamanın parolayı hazır verdiği tek kullanımlık boru (`PasswordPipe`); askpass Anahtar Zinciri'ne gitmez.
        public static let passwordPipe = "SSHMANAGER_ASKPASS_PIPE"
    }

    /// ssh'ın parola/onay sorularını `helper` programına sormasını sağlayan ortam.
    /// OpenSSH 8.4+ gerektirir (SSH_ASKPASS_REQUIRE=force); macOS'taki sürüm bunu destekler.
    public static func askpassEnvironment(helper: String, serverID: UUID) -> [String: String] {
        [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            Env.askpassFlag: "1",
            Env.serverID: serverID.uuidString,
        ]
    }

    /// Her bağlantıda ortak seçenekler: kapı, anahtar, bağlantıyı canlı tutma.
    public static func baseOptions(for s: Server) -> [String] {
        var args = ["-p", String(s.port)]
        if !s.identityFile.isEmpty {
            args += ["-i", Paths.expandTilde(s.identityFile)]
        }
        args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4"]
        return args
    }

    /// Bağlandıktan sonra sunucuda çalışacak komut. Yoksa nil (normal kabuk açılır).
    public static func remoteCommand(for s: Server) -> String? {
        var parts: [String] = []
        let post = s.postCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !post.isEmpty { parts.append(post) }
        if s.useTmux {
            // tmux yoksa normal kabuğa düş.
            parts.append("if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s sshmanager; else exec \"$SHELL\" -l; fi")
        } else if !parts.isEmpty {
            parts.append("exec \"$SHELL\" -l")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Etkileşimli oturum: `ssh [seçenekler] [-t] -- user@host [komut]`
    public static func interactiveArguments(for s: Server) -> [String] {
        var args = baseOptions(for: s)
        if let remote = remoteCommand(for: s) {
            args += ["-t", "--", s.sshDestination, remote]
        } else {
            args += ["--", s.sshDestination]
        }
        return args
    }

    /// Sunucuda tek bir komut çalıştırıp çıkar (sshm sunucu 'uptime').
    public static func commandArguments(for s: Server, remoteCommand: String, tty: Bool) -> [String] {
        baseOptions(for: s) + (tty ? ["-t"] : []) + ["--", s.sshDestination, remoteCommand]
    }

    /// Arka planda tünel: ssh -N -L yerel:uzakHost:uzakKapı
    public static func tunnelArguments(for s: Server, tunnel t: Tunnel) -> [String] {
        baseOptions(for: s) + [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:\(t.localPort):\(t.remoteHost):\(t.remotePort)",
            "--", s.sshDestination,
        ]
    }

    /// Kopyalanıp terminale yapıştırılabilecek karşılığı (parolasız, bilgi amaçlı).
    public static func displayCommand(for s: Server) -> String {
        (["ssh"] + interactiveArguments(for: s).filter { $0 != "--" }).map(shellQuote).joined(separator: " ")
    }

    /// Kabukta tek argüman olarak güvenle kullanılabilecek hale getirir.
    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// ssh'ın askpass programına sorduğu sorunun türü.
public enum AskPassPrompt: Equatable {
    case password
    case passphrase
    case hostKey
    case confirm
    case other

    /// `SSH_ASKPASS_PROMPT` ssh tarafından "confirm" (evet/hayır) veya "none" (sadece bilgi) olarak verilir.
    public static func classify(_ prompt: String, promptEnv: String? = nil) -> AskPassPrompt {
        let p = prompt.lowercased()
        if promptEnv == "confirm" { return .confirm }
        if p.contains("(yes/no") || p.contains("continue connecting") { return .hostKey }
        if p.contains("passphrase") { return .passphrase }
        if p.contains("password") || p.contains("parola") || p.contains("şifre") { return .password }
        return .other
    }
}

/// ~/.ssh/config içindeki sunucuları okur (joker karakterli Host kalıpları atlanır).
public enum SSHConfigImporter {
    public struct Entry: Equatable {
        public var alias: String
        public var hostName: String
        public var user: String?
        public var port: Int?
        public var identityFile: String?
    }

    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [Entry] = []   // "Host a b" birden çok ad verebilir
        var inMatch = false

        func flush() {
            entries += current
            current = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // "Anahtar değer" ya da "Anahtar=değer"
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))

            switch key {
            case "host":
                flush()
                inMatch = false
                for pattern in value.split(separator: " ").map(String.init)
                where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                    current.append(Entry(alias: pattern, hostName: pattern))
                }
            case "match":
                flush()
                inMatch = true
            default:
                guard !inMatch else { continue }
                for i in current.indices {
                    switch key {
                    case "hostname": current[i].hostName = value
                    case "user": current[i].user = value
                    case "port": current[i].port = Int(value)
                    case "identityfile": if current[i].identityFile == nil { current[i].identityFile = value }
                    default: break
                    }
                }
            }
        }
        flush()
        return entries
    }

    /// Mevcut listede olmayanları Server'a çevirir (aynı kullanıcı+host+port varsa atlar).
    public static func newServers(from entries: [Entry], existing: [Server], defaultUser: String) -> [Server] {
        var seen = Set(existing.map { "\($0.user)@\($0.host.lowercased()):\($0.port)" })
        var result: [Server] = []
        for e in entries {
            var s = Server(name: e.alias, host: e.hostName, port: e.port ?? 22, user: e.user ?? defaultUser)
            s.identityFile = e.identityFile ?? ""
            s.group = "İçe aktarılan"
            let key = "\(s.user)@\(s.host.lowercased()):\(s.port)"
            guard s.validationError == nil, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(s)
        }
        return result
    }
}

/// Aynı ssh sürecinin kaçıncı kez parola sorduğunu sayar: ilk denemede kayıtlı parola verilir,
/// sonrakilerde (parola yanlışsa) kullanıcıya sorulur.
public enum AttemptCounter {
    public static func next(key: String, directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> Int {
        let file = directory.appendingPathComponent("sshmanager-askpass-\(key)")
        let fm = FileManager.default
        // Bir günden eski sayaçlar başka süreçlere ait olabilir; yok say.
        if let attrs = try? fm.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) > 3600 {
            try? fm.removeItem(at: file)
        }
        let current = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0) } ?? 0
        let next = current + 1
        try? String(next).write(to: file, atomically: true, encoding: .utf8)
        return next
    }
}
