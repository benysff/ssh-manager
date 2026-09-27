import AppKit
import SSHManagerKit

// Aynı program dört rolde çalışır; hangisi olduğu nasıl çağrıldığından anlaşılır:
//  1. mc'nin çağırdığı "ssh" ara katmanı          → SSHShim: sunucunun kapı/anahtar ayarlarını ekler
//  2. ssh parola sorduğunda (SSH_ASKPASS)        → AskPass: Keychain'den verir ya da native pencereyle sorar
//  3. Terminalden "sshm ..." ya da "SSHManager connect ..." → CLI
//  4. Hiçbiri değilse                            → menü çubuğu uygulaması

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment
let invokedAs = URL(fileURLWithPath: arguments[0]).lastPathComponent
let rest = Array(arguments.dropFirst())

if invokedAs == "ssh", let id = environment[SSHCommand.Env.shimServerID] {
    SSHShim.run(serverID: id, arguments: rest)
}

if environment[SSHCommand.Env.askpassFlag] == "1" {
    exit(AskPass.run(arguments: rest))
}

if invokedAs == "sshm" || CLI.isCommand(rest.first) {
    exit(CLI.run(rest))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
