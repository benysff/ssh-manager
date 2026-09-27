import Foundation
import SSHManagerKit

/// Terminalden kullanım:
///   sshm                      sunucuları listele
///   sshm <sunucu>             bağlan
///   sshm <sunucu> <komut…>    sunucuda komut çalıştır (ör. sshm web 'df -h')
///   sshm files <sunucu>       Midnight Commander ile dosyalar (solda Mac'in, sağda sunucu)
///   sshm durum [sunucu]       sunucuların sağlığı (disk, bellek, yük, güncellemeler)
enum CLI {
    private static let commands: Set<String> = ["connect", "files", "list", "ls", "help", "--help", "-h", "--complete", "_betik",
                                                "durum", "status", "_uzak", "_parola"]

    static func isCommand(_ arg: String?) -> Bool {
        arg.map { commands.contains($0) } ?? false
    }

    static func run(_ args: [String]) -> Int32 {
        let store = ServerStore.shared
        if let error = store.loadError {
            fail(error)
            return 1
        }
        guard let first = args.first else {
            list(store)
            return 0
        }
        switch first {
        case "list", "ls":
            list(store)
            return 0
        case "--complete":
            store.aliases().forEach { print($0.alias) }
            return 0
        case "help", "--help", "-h":
            usage()
            return 0
        case "_betik":
            // Geliştirici aracı: bağlanırken çalıştırılacak AppleScript'i yazdırır (sshm _betik <ad> | osascript).
            guard let server = resolve(args.dropFirst().first, store) else { return 1 }
            print(TerminalLauncher.script(for: ["connect", server.id.uuidString], title: server.name, theme: server.theme))
            return 0
        case "durum", "status":
            let targets: [Server]
            if let q = args.dropFirst().first {
                guard let s = resolve(q, store) else { return 1 }
                targets = [s]
            } else {
                targets = store.servers
            }
            return status(targets)
        case "_parola":
            // Geliştirici aracı: sunucunun parolasını stdin'den okuyup Anahtar Zinciri'ne bu uygulama adına kaydeder.
            guard let server = resolve(args.dropFirst().first, store), let pw = readLine(strippingNewline: true), !pw.isEmpty else { return 1 }
            return KeychainHelper.savePassword(pw, account: server.keychainAccount) ? 0 : 1
        case "_uzak":
            // Geliştirici aracı: sunucuda uygulamanın betiklerini pencere açmadan çalıştırır.
            //   sshm _uzak <ad> saglik | guncelleme-kontrol | guncelle | guvenlik-guncelle
            guard args.count >= 3, let server = resolve(args[1], store) else { return 1 }
            let scripts = ["saglik": (RemoteScripts.health, false), "guncelleme-kontrol": (RemoteScripts.updateCheck, true),
                           "guncelle": (RemoteScripts.updateApply(securityOnly: false), true),
                           "guvenlik-guncelle": (RemoteScripts.updateApply(securityOnly: true), true)]
            guard let (script, root) = scripts[args[2]] else { fail("Bilinmeyen betik: \(args[2])"); return 1 }
            var code: Int32 = 0
            var finished = false
            RemoteRun(server: server).start(command: script, asRoot: root, mode: .silent, timeout: 3600) { r in
                print(r.output, terminator: "")
                print("\n[çıkış kodu \(r.exitCode)\(r.timedOut ? ", zaman aşımı" : "")]")
                code = r.exitCode
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return code
        case "connect":
            guard let server = resolve(args.dropFirst().first, store) else { return 1 }
            connect(server)
        case "files":
            guard let server = resolve(args.dropFirst().first, store) else { return 1 }
            files(server)
        default:
            guard let server = resolve(first, store) else { return 1 }
            let command = args.dropFirst().joined(separator: " ")
            if command.isEmpty { connect(server) }
            let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
            execSSH(server, SSHCommand.commandArguments(for: server, remoteCommand: command, tty: tty))
        }
    }

    // MARK: - Komutlar

    private static func connect(_ server: Server) -> Never {
        execSSH(server, SSHCommand.interactiveArguments(for: server))
    }

    private static func files(_ server: Server) -> Never {
        guard let mc = findMC() else {
            fail("Midnight Commander kurulu değil. Kurmak için:  brew install mc")
            exit(1)
        }
        // mc sunucuya kendi "ssh" çağrısıyla bağlanır. PATH'in başına koyduğumuz ara katman,
        // o çağrıya sunucunun kapı/anahtar ayarlarını ekler; parolayı da askpass verir.
        let shimDir = AppPaths.caches.appendingPathComponent("shim", isDirectory: true)
        let shim = shimDir.appendingPathComponent("ssh")
        let fm = FileManager.default
        try? fm.createDirectory(at: shimDir, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: shim.path)) != AppPaths.executable {
            try? fm.removeItem(at: shim)
            try? fm.createSymbolicLink(atPath: shim.path, withDestinationPath: AppPaths.executable)
        }
        var env = askpassEnv(server)
        env[SSHCommand.Env.shimServerID] = server.id.uuidString
        env["PATH"] = shimDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let remote = "sh://\(server.sshDestination)/~"  // sağ panel sunucudaki ev klasöründe açılır
        execProgram(mc, ["mc", NSHomeDirectory(), remote], env: env)
    }

    /// sshm durum: sunucuların sağlığı tablo halinde (arka plandaki kontrolle aynı, pencere açmaz).
    private static func status(_ servers: [Server]) -> Int32 {
        guard !servers.isEmpty else { print("Henüz sunucu yok."); return 0 }
        var reports: [UUID: HealthReport] = [:]
        let queue = BatchQueue(limit: 6)
        for s in servers {
            queue.add { done in
                RemoteRun(server: s).start(command: RemoteScripts.health, asRoot: false, mode: .silent, timeout: 45) { r in
                    reports[s.id] = r.output.contains("BD_OK=1")
                        ? HealthReport.from(output: r.output)
                        : HealthReport.failure(output: r.timedOut ? "timed out" : r.output)
                    done()
                }
            }
        }
        while reports.count < servers.count { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        let colors: [HealthLevel: String] = [.ok: "32", .warn: "33", .bad: "31", .unknown: "90"]
        let width = min(max(servers.map(\.name.count).max() ?? 8, 8), 28)
        var worst = HealthLevel.unknown
        for s in servers.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let r = reports[s.id]!
            let ev = r.evaluation
            worst = max(worst, ev.level)
            let name = s.name.count > width ? String(s.name.prefix(width - 1)) + "…" : s.name
            let pad = String(repeating: " ", count: max(1, width - name.count + 2))
            var cols: [String] = []
            if r.reachable {
                cols.append("disk " + (r.disk.map { "%\($0)" } ?? "—"))
                cols.append("bellek " + (r.memory.map { "%\($0)" } ?? "—"))
                cols.append("yük " + (r.load.map { String(format: "%.2f", $0) } ?? "—"))
                if let u = r.updates { cols.append(u == 0 ? "güncel" : "\(u) güncelleme") }
            }
            let detail = ev.issues.isEmpty ? "" : "  \u{1B}[\(colors[ev.level]!)m\(ev.issues.joined(separator: " · "))\u{1B}[0m"
            print("\u{1B}[\(colors[ev.level]!)m●\u{1B}[0m \(name)\(pad)\(cols.joined(separator: "  "))\(detail)")
        }
        return worst == .bad ? 2 : 0
    }

    private static func list(_ store: ServerStore) {
        let aliases = store.aliases()
        if aliases.isEmpty {
            print("Henüz sunucu yok. Menü çubuğundaki SSHManager simgesinden ekleyebilirsin.")
            return
        }
        let width = min(max(aliases.map(\.alias.count).max() ?? 0, 8), 32)
        for (group, servers) in store.grouped() {
            print("\u{1B}[1m\(group)\u{1B}[0m")
            for s in servers {
                let alias = store.alias(of: s)
                var flags: [String] = []
                if KeychainHelper.hasPassword(account: s.keychainAccount) { flags.append("parola") }
                if !s.identityFile.isEmpty { flags.append("anahtar") }
                if s.useTmux { flags.append("tmux") }
                if !s.tunnels.isEmpty { flags.append("tünel") }
                let pad = String(repeating: " ", count: max(1, width - alias.count + 2))
                let dest = "\(s.sshDestination)\(s.port == 22 ? "" : ":\(s.port)")"
                print("  \(alias)\(pad)\(dest)\(flags.isEmpty ? "" : "  \u{1B}[2m[\(flags.joined(separator: ", "))]\u{1B}[0m")")
            }
        }
        print("\nBağlanmak için: sshm <ad>   ·   Komut çalıştırmak için: sshm <ad> 'komut'")
    }

    private static func usage() {
        print("""
        sshm — SSHManager komut satırı

          sshm                      sunucuları listele
          sshm <ad>                 bağlan (parola Anahtar Zinciri'nden gelir)
          sshm <ad> <komut…>        sunucuda komut çalıştır, ör: sshm web 'df -h'
          sshm files <ad>           dosyalar: Midnight Commander (solda Mac'in, sağda sunucu)
          sshm durum [ad]           sunucuların sağlığı: disk, bellek, yük, güncellemeler, sorunlar

        <ad> yerine sunucunun kısa adı, tam adı ya da host adresi yazılabilir.
        """)
    }

    // MARK: - Yardımcılar

    private static func resolve(_ query: String?, _ store: ServerStore) -> Server? {
        guard let query = query, !query.isEmpty else {
            fail("Sunucu adı eksik. Liste için: sshm")
            return nil
        }
        guard let server = store.find(query) else {
            fail("Sunucu bulunamadı: \(query). Liste için: sshm")
            return nil
        }
        return server
    }

    static func askpassEnv(_ server: Server) -> [String: String] {
        SSHCommand.askpassEnvironment(helper: AppPaths.executable, serverID: server.id)
    }

    private static func execSSH(_ server: Server, _ args: [String]) -> Never {
        execProgram(SSHCommand.sshPath, ["ssh"] + args, env: askpassEnv(server))
    }

    /// Bu süreci verilen programla değiştirir (terminal doğrudan ssh/mc'ye bağlanır).
    static func execProgram(_ path: String, _ argv: [String], env: [String: String]) -> Never {
        for (key, value) in env { setenv(key, value, 1) }
        let cArgs = argv.map { strdup($0) } + [nil]
        execv(path, cArgs)
        fail("\(path) çalıştırılamadı: \(String(cString: strerror(errno)))")
        exit(127)
    }

    static func findMC() -> String? {
        let paths = ["/opt/homebrew/bin/mc", "/usr/local/bin/mc"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/mc" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("sshm: \(message)\n".utf8))
    }
}

/// mc'nin "ssh" çağrısına sunucunun ayarlarını (kapı, anahtar, canlı tutma) ekleyip gerçek ssh'ı çalıştırır.
enum SSHShim {
    static func run(serverID: String, arguments: [String]) -> Never {
        var args = arguments
        if let id = UUID(uuidString: serverID), let server = ServerStore.shared.server(id: id) {
            args = SSHCommand.baseOptions(for: server) + arguments
        }
        CLI.execProgram(SSHCommand.sshPath, ["ssh"] + args, env: [:])
    }
}
