import Foundation
import SSHManagerKit

/// Arka planda çalışan ssh tünellerini (ssh -N -L) yönetir.
final class TunnelManager {
    static let shared = TunnelManager()

    struct Key: Hashable {
        let serverID: UUID
        let tunnel: Tunnel
    }

    /// Tünel durumu değişince (açıldı / kapandı) çağrılır; ana iş parçacığında.
    var onChange: (() -> Void)?
    /// Tünel beklenmedik şekilde kapanınca hata mesajıyla çağrılır; ana iş parçacığında.
    var onFailure: ((Server, Tunnel, String) -> Void)?

    private var running: [Key: Process] = [:]
    private var stopping: Set<Key> = []

    var activeCount: Int { running.count }

    func isActive(_ server: Server, _ tunnel: Tunnel) -> Bool {
        running[Key(serverID: server.id, tunnel: tunnel)] != nil
    }

    func start(_ server: Server, _ tunnel: Tunnel) throws {
        let key = Key(serverID: server.id, tunnel: tunnel)
        guard running[key] == nil else { return }
        guard Self.isPortFree(tunnel.localPort) else {
            throw SSHManagerError.failed("localhost:\(tunnel.localPort) zaten kullanımda. Tünel için başka bir yerel kapı seç.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.sshPath)
        process.arguments = SSHCommand.tunnelArguments(for: server, tunnel: tunnel)
        process.environment = ProcessInfo.processInfo.environment.merging(CLI.askpassEnv(server)) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        process.terminationHandler = { [weak self] proc in
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running[key] = nil
                let expected = self.stopping.remove(key) != nil
                if !expected {
                    let reason = message.isEmpty ? "ssh kapandı (kod \(proc.terminationStatus))." : message
                    self.onFailure?(server, tunnel, reason)
                }
                self.onChange?()
            }
        }
        try process.run()
        running[key] = process
        onChange?()
    }

    func stop(_ server: Server, _ tunnel: Tunnel) {
        let key = Key(serverID: server.id, tunnel: tunnel)
        guard let process = running[key] else { return }
        stopping.insert(key)
        process.terminate()
    }

    func stopAll() {
        for (key, process) in running {
            stopping.insert(key)
            process.terminate()
        }
    }

    /// Sunucu silinince ya da tünel listesi değişince artık tanımsız olan tünelleri kapatır.
    func prune(keeping servers: [Server]) {
        for (key, process) in running {
            let still = servers.first { $0.id == key.serverID }?.tunnels.contains(key.tunnel) ?? false
            if !still {
                stopping.insert(key)
                process.terminate()
            }
        }
    }

    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
