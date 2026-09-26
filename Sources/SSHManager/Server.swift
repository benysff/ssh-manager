import Foundation

/// Bir SSH sunucu kaydı. Parola burada TUTULMAZ; Keychain'de saklanır.
struct Server: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String          // Menüde görünecek ad
    var host: String          // IP veya hostname
    var port: Int = 22
    var user: String
    var group: String = ""    // Boşsa "Genel" altında listelenir
    var postCommand: String = "" // Bağlandıktan sonra çalışacak komut (opsiyonel)

    /// Keychain'de parolayı bulmak için kullanılan benzersiz hesap anahtarı.
    var keychainAccount: String { id.uuidString }

    /// ssh komutu için "user@host" gösterimi.
    var sshDestination: String { "\(user)@\(host)" }
}

/// Sunucu kayıtlarını diske yazıp okuyan basit JSON store.
final class ServerStore {
    static let shared = ServerStore()

    private(set) var servers: [Server] = []

    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SSHManager", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("servers.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            servers = []
            return
        }
        servers = (try? JSONDecoder().decode([Server].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(servers) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ server: Server) {
        servers.append(server)
        save()
    }

    func update(_ server: Server) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        save()
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        KeychainHelper.deletePassword(account: server.keychainAccount)
        save()
    }

    /// Sunucuları gruba göre alfabetik düzenler. Boş grup "Genel" olur.
    func grouped() -> [(group: String, servers: [Server])] {
        let dict = Dictionary(grouping: servers) { $0.group.isEmpty ? "Genel" : $0.group }
        return dict
            .map { (group: $0.key, servers: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending }
    }
}
