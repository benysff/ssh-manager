import Foundation
import Testing
@testable import SSHManagerKit

@Suite struct ServerDecodingTests {
    /// Eski sürümün yazdığı dosya (yeni alanlar yok) sorunsuz okunmalı.
    @Test func testDecodesOldFormat() throws {
        let json = """
        [{"group":"Genel","host":"10.0.0.5","id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF",
          "name":"Web","port":2222,"postCommand":"cd /var/www","user":"root"}]
        """
        let servers = try JSONDecoder().decode([Server].self, from: Data(json.utf8))
        #expect(servers.count == 1)
        let s = servers[0]
        #expect(s.port == 2222)
        #expect(s.postCommand == "cd /var/www")
        #expect(s.identityFile == "")
        #expect(s.theme == .none)
        #expect(!(s.useTmux))
        #expect(s.tunnels == [])
        #expect(s.id.uuidString == "6F9619FF-8B86-D011-B42D-00CF4FC964FF")
    }

    @Test func testRoundTrip() throws {
        var s = Server(name: "DB", host: "db.example.com", user: "admin")
        s.theme = .red
        s.useTmux = true
        s.tunnels = [Tunnel(localPort: 5433, remotePort: 5432)]
        let data = try JSONEncoder().encode([s])
        #expect(try JSONDecoder().decode([Server].self, from: data) == [s])
    }

    /// Okunamayan dosyanın üzerine asla yazılmamalı.
    @Test func testStoreRefusesToOverwriteUnreadableFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("servers.json")
        try Data("bozuk{".utf8).write(to: file)
        let store = ServerStore(fileURL: file)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.add(Server(name: "x", host: "h", user: "u")) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "bozuk{")
    }

    @Test func testAliasesAndFind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ServerStore(fileURL: dir.appendingPathComponent("servers.json"))
        try store.add(Server(name: "Üretim Sunucusu", host: "1.2.3.4", user: "root"))
        try store.add(Server(name: "Üretim sunucusu", host: "5.6.7.8", user: "root"))
        #expect(store.aliases().map(\.alias) == ["uretim-sunucusu", "uretim-sunucusu-2"])
        #expect(store.find("uretim-sunucusu-2")?.host == "5.6.7.8")
        #expect(store.find("1.2.3.4")?.name == "Üretim Sunucusu")
        #expect(store.find("yok") == nil)
    }
}

@Suite struct ValidationTests {
    @Test func testRejectsOptionInjection() {
        #expect(!(Server.isValidHost("-oProxyCommand=calc")))
        #expect(!(Server.isValidHost("host name")))
        #expect(!(Server.isValidUser("-l")))
        #expect(Server.isValidHost("192.168.1.10"))
        #expect(Server.isValidHost("fe80::1%en0"))
        #expect(Server.isValidHost("sunucu.ornek.com"))
        #expect(Server.isValidUser("deploy_user"))
    }

    @Test func testSlug() {
        #expect(Server.slugify("Canlı Web Sunucusu (İstanbul)") == "canli-web-sunucusu-istanbul")
        #expect(Server.slugify("***") == "sunucu")
    }
}

@Suite struct CommandTests {
    @Test func testInteractivePlain() {
        let s = Server(name: "a", host: "h.com", port: 2200, user: "u")
        #expect(SSHCommand.interactiveArguments(for: s) == ["-p", "2200", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4", "--", "u@h.com"])
    }

    /// Bağlantı sonrası komut tek argüman olarak sunucuya gider; yerel kabukta açılmaz.
    @Test func testPostCommandIsSingleRemoteArgument() {
        var s = Server(name: "a", host: "h", user: "u")
        s.postCommand = "cd $HOME/app && echo \"$(whoami)\""
        let args = SSHCommand.interactiveArguments(for: s)
        #expect(Array(args.suffix(4)) == ["-t", "--", "u@h", "cd $HOME/app && echo \"$(whoami)\"; exec \"$SHELL\" -l"])
    }

    @Test func testTmuxAndIdentity() {
        var s = Server(name: "a", host: "h", user: "u")
        s.useTmux = true
        s.identityFile = "~/.ssh/id_ed25519"
        let args = SSHCommand.interactiveArguments(for: s)
        #expect(args.contains("-i"))
        #expect(!(args[args.firstIndex(of: "-i")! + 1].hasPrefix("~")))
        #expect(args.last!.contains("tmux new-session -A -s sshmanager"))
    }

    @Test func testTunnelArguments() {
        let s = Server(name: "a", host: "h", user: "u")
        let args = SSHCommand.tunnelArguments(for: s, tunnel: Tunnel(localPort: 5433, remotePort: 5432))
        #expect(args.contains("-N"))
        #expect(args.contains("127.0.0.1:5433:localhost:5432"))
        #expect(args.last == "u@h")
    }

    @Test func testShellQuote() {
        #expect(SSHCommand.shellQuote("abc-1.2") == "abc-1.2")
        #expect(SSHCommand.shellQuote("it's here") == "'it'\\''s here'")
        #expect(SSHCommand.shellQuote("") == "''")
    }
}

@Suite struct TunnelParseTests {
    @Test func testParseList() throws {
        let list = try Tunnel.parseList("5433:5432, 8080:web:80")
        #expect(list == [Tunnel(localPort: 5433, remotePort: 5432), Tunnel(localPort: 8080, remoteHost: "web", remotePort: 80)])
        #expect(list.map(\.spec) == ["5433:5432", "8080:web:80"])
        #expect(try Tunnel.parseList("") == [])
    }

    @Test func testParseErrors() {
        #expect(throws: (any Error).self) { try Tunnel.parse("5433") }
        #expect(throws: (any Error).self) { try Tunnel.parse("99999:22") }
        #expect(throws: (any Error).self) { try Tunnel.parse("1:-evil:2") }
    }
}

@Suite struct AskPassTests {
    @Test func testClassify() {
        #expect(AskPassPrompt.classify("root@1.2.3.4's password: ") == .password)
        #expect(AskPassPrompt.classify("(root@host) Password:") == .password)
        #expect(AskPassPrompt.classify("Enter passphrase for key '/Users/x/.ssh/id_ed25519': ") == .passphrase)
        #expect(AskPassPrompt.classify("The authenticity of host 'x' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ") == .hostKey)
        #expect(AskPassPrompt.classify("Allow use of key?", promptEnv: "confirm") == .confirm)
        #expect(AskPassPrompt.classify("Verification code: ") == .other)
    }

    @Test func testAttemptCounter() {
        let dir = FileManager.default.temporaryDirectory
        let key = UUID().uuidString
        #expect(AttemptCounter.next(key: key, directory: dir) == 1)
        #expect(AttemptCounter.next(key: key, directory: dir) == 2)
    }
}

@Suite struct ImporterTests {
    @Test func testParseConfig() {
        let text = """
        # yorum
        Host *
            ServerAliveInterval 60
        Host web prod-web
            HostName 10.0.0.5
            User deploy
            Port 2222
            IdentityFile ~/.ssh/deploy_key
        Host db
          HostName=db.internal
        Match host foo
            User ignored
        """
        let entries = SSHConfigImporter.parse(text)
        #expect(entries.map(\.alias) == ["web", "prod-web", "db"])
        #expect(entries[0].hostName == "10.0.0.5")
        #expect(entries[1].port == 2222)
        #expect(entries[0].identityFile == "~/.ssh/deploy_key")
        #expect(entries[2].hostName == "db.internal")
        #expect(entries[2].user == nil)

        let existing = [Server(name: "x", host: "10.0.0.5", port: 2222, user: "deploy")]
        let new = SSHConfigImporter.newServers(from: entries, existing: existing, defaultUser: "me")
        #expect(new.map(\.name) == ["db"])
        #expect(new[0].user == "me")
    }
}
