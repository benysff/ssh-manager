import Foundation
import SSHManagerKit

/// Terminalden kullanım:
///   sshm                      sunucuları listele
///   sshm <sunucu>             bağlan
///   sshm <sunucu> <komut…>    sunucuda komut çalıştır (ör. sshm web 'df -h')
///   sshm files <sunucu>       Midnight Commander ile dosyalar (solda Mac'in, sağda sunucu)
enum CLI {
    private static let commands: Set<String> = ["connect", "files", "list", "ls", "help", "--help", "-h", "--complete", "_betik"]

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
