import Foundation

/// Terminal penceresinin rengi. Canlı ortamı kırmızı açmak gibi, yanlış sunucuda
/// komut çalıştırma riskini azaltmak için.
public enum ServerTheme: String, Codable, CaseIterable {
    case none, red, green, blue

    public var title: String {
        switch self {
        case .none: return "Varsayılan"
        case .red: return "Kırmızı (canlı ortam)"
        case .green: return "Yeşil (test ortamı)"
        case .blue: return "Mavi"
        }
    }
}

/// Yerel bir kapıyı sunucu üzerinden uzaktaki bir kapıya bağlayan tünel (ssh -L).
public struct Tunnel: Codable, Equatable, Hashable {
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(localPort: Int, remoteHost: String = "localhost", remotePort: Int) {
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    /// "5433:5432" veya "5433:db:5432" biçimi.
    public var spec: String {
        remoteHost == "localhost" ? "\(localPort):\(remotePort)" : "\(localPort):\(remoteHost):\(remotePort)"
    }

    public var title: String {
        "localhost:\(localPort) → \(remoteHost == "localhost" ? "" : remoteHost + ":")\(remotePort)"
    }

    /// Virgül veya boşlukla ayrılmış tünel listesini okur. Hatalı parçada açıklayıcı hata verir.
    public static func parseList(_ text: String) throws -> [Tunnel] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        return try parts.map(parse)
    }

    public static func parse(_ item: String) throws -> Tunnel {
        let fields = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func port(_ s: String) throws -> Int {
            guard let p = Int(s), (1...65535).contains(p) else {
                throw SSHManagerError.invalid("Tünelde geçersiz kapı: '\(item)'")
            }
            return p
        }
        switch fields.count {
        case 2:
            return Tunnel(localPort: try port(fields[0]), remotePort: try port(fields[1]))
        case 3:
            let host = fields[1]
            guard Server.isValidHost(host) else { throw SSHManagerError.invalid("Tünelde geçersiz sunucu adı: '\(item)'") }
            return Tunnel(localPort: try port(fields[0]), remoteHost: host, remotePort: try port(fields[2]))
        default:
            throw SSHManagerError.invalid("Tünel anlaşılamadı: '\(item)'. Biçim: yerelKapı:uzakKapı (ör. 5433:5432)")
        }
    }
}

public enum SSHManagerError: Error, LocalizedError, Equatable {
    case invalid(String)
    case notFound(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m), .notFound(let m), .failed(let m): return m
        }
    }
}

/// Bir SSH sunucu kaydı. Parola burada TUTULMAZ; Keychain'de saklanır.
public struct Server: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var name: String            // Menüde görünecek ad
    public var host: String            // IP veya hostname
    public var port: Int = 22
    public var user: String
    public var group: String = ""      // Boşsa "Genel" altında listelenir
    public var postCommand: String = "" // Bağlandıktan sonra uzakta çalışacak komut (opsiyonel)
    public var identityFile: String = "" // SSH anahtarı (boşsa ssh'ın varsayılanları)
    public var theme: ServerTheme = .none
    public var useTmux: Bool = false   // Bağlantı koparsa kaldığı yerden devam
    public var tunnels: [Tunnel] = []

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, user: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
    }

    /// Keychain'de parolayı bulmak için kullanılan benzersiz hesap anahtarı.
    public var keychainAccount: String { id.uuidString }

    /// ssh komutu için "user@host" gösterimi.
    public var sshDestination: String { "\(user)@\(host)" }

    /// Komut satırında kullanılan kısa ad (ör. "Production Web" → "production-web").
    public var slug: String { Server.slugify(name) }

    public var displayGroup: String { group.isEmpty ? "Genel" : group }

    // Eski sürümlerin kaydettiği dosyalarda yeni alanlar yok; eksikler varsayılana düşer.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, group, postCommand, identityFile, theme, useTmux, tunnels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try c.decode(String.self, forKey: .user)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        postCommand = try c.decodeIfPresent(String.self, forKey: .postCommand) ?? ""
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        theme = (try? c.decodeIfPresent(ServerTheme.self, forKey: .theme)) ?? ServerTheme.none
        useTmux = try c.decodeIfPresent(Bool.self, forKey: .useTmux) ?? false
        tunnels = try c.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
    }

    // MARK: - Doğrulama

    /// Host "-" ile başlayamaz: ssh bunu seçenek sanar (ör. -oProxyCommand=...).
    public static func isValidHost(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.range(of: #"^[A-Za-z0-9._:%\[\]-]+$"#, options: .regularExpression) != nil
    }

    public static func isValidUser(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.range(of: #"^[A-Za-z0-9._@\\-]+$"#, options: .regularExpression) != nil
    }

    /// Kaydetmeden önce kontrol; sorun yoksa nil.
    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Ad boş olamaz." }
        if !Server.isValidHost(host) { return "Host geçersiz. Örnek: 192.168.1.10 veya sunucu.ornek.com" }
        if !Server.isValidUser(user) { return "Kullanıcı adı geçersiz." }
        if !(1...65535).contains(port) { return "Port 1 ile 65535 arasında olmalı." }
        return nil
    }

    public static func slugify(_ text: String) -> String {
        let map: [Character: String] = ["ı": "i", "İ": "i", "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g",
                                        "ü": "u", "Ü": "u", "ö": "o", "Ö": "o", "ç": "c", "Ç": "c"]
        var out = ""
        var lastDash = false
        for ch in text {
            let s = (map[ch] ?? String(ch)).lowercased()
            if s.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil {
                out += s
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out += "-"
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "sunucu" : out
    }
}

/// Uygulamanın dosya yolları. Testlerde SSHMANAGER_DATA_DIR ile değiştirilebilir.
public enum Paths {
    public static var dataDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["SSHMANAGER_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SSHManager", isDirectory: true)
    }

    public static var serversFile: URL { dataDirectory.appendingPathComponent("servers.json") }

    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// Sunucu kayıtlarını diske yazıp okuyan basit JSON store.
public final class ServerStore {
    public static let shared = ServerStore()

    public private(set) var servers: [Server] = []
    /// Dosya var ama okunamadıysa burada açıklama durur ve kayıt yapılmaz
    /// (bozuk ya da yeni sürüm dosyasının üzerine yazıp veriyi silmemek için).
    public private(set) var loadError: String?

    private let fileURL: URL

    public init(fileURL: URL = Paths.serversFile) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    public func load() {
        loadError = nil
        guard let data = try? Data(contentsOf: fileURL) else {
            servers = []
            return
        }
        do {
            servers = try JSONDecoder().decode([Server].self, from: data)
        } catch {
            servers = []
            loadError = "Sunucu listesi okunamadı (\(fileURL.path)): \(error.localizedDescription)"
        }
    }

    public func save() throws {
        if let loadError = loadError { throw SSHManagerError.failed(loadError) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(servers)
        try data.write(to: fileURL, options: .atomic)
    }

    public func add(_ server: Server) throws {
        servers.append(server)
        try save()
    }

    public func update(_ server: Server) throws {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        try save()
    }

    public func remove(_ server: Server) throws {
        servers.removeAll { $0.id == server.id }
        try save()
        KeychainHelper.deletePassword(account: server.keychainAccount)
        KeychainHelper.deletePassword(account: server.keychainAccount + "-sudo")
    }

    public func server(id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    /// Her sunucu için benzersiz kısa ad (aynı ada sahip olanlara -2, -3 eklenir).
    public func aliases() -> [(alias: String, server: Server)] {
        var used: [String: Int] = [:]
        return servers.map { s in
            let base = s.slug
            let n = (used[base] ?? 0) + 1
            used[base] = n
            return (n == 1 ? base : "\(base)-\(n)", s)
        }
    }

    public func alias(of server: Server) -> String {
        aliases().first { $0.server.id == server.id }?.alias ?? server.slug
    }

    /// Kısa ad, tam ad, host ya da UUID ile sunucu bulur.
    public func find(_ query: String) -> Server? {
        if let uuid = UUID(uuidString: query), let s = server(id: uuid) { return s }
        let q = query.lowercased()
        if let hit = aliases().first(where: { $0.alias == q }) { return hit.server }
        if let hit = servers.first(where: { $0.name.lowercased() == q }) { return hit }
        let byHost = servers.filter { $0.host.lowercased() == q }
        return byHost.count == 1 ? byHost[0] : nil
    }

    /// Sunucuları gruba göre alfabetik düzenler. Boş grup "Genel" olur.
    public func grouped() -> [(group: String, servers: [Server])] {
        let dict = Dictionary(grouping: servers) { $0.displayGroup }
        return dict
            .map { (group: $0.key, servers: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending }
    }
}
