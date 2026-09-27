import Foundation

/// Sunucularda çalıştırılabilen kayıtlı komut.
public struct Snippet: Codable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var command: String
    /// Yönetici (root/sudo) olarak çalışsın mı?
    public var asRoot: Bool
    /// Sistemi değiştiren komut: canlı (kırmızı) sunucularda ekstra onay istenir.
    public var changesSystem: Bool
    public var builtin: Bool

    public init(id: String = UUID().uuidString, name: String, command: String,
                asRoot: Bool = false, changesSystem: Bool = false, builtin: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.asRoot = asRoot
        self.changesSystem = changesSystem
        self.builtin = builtin
    }

    /// Hazır komutlar: bilgi amaçlı olanlar sistemi değiştirmez.
    public static let builtins: [Snippet] = [
        Snippet(id: "disk", name: "Disk durumu",
                command: "df -h -x tmpfs -x devtmpfs -x squashfs -x overlay", builtin: true),
        Snippet(id: "bellek", name: "Bellek ve yük",
                command: "free -h && echo && uptime", builtin: true),
        Snippet(id: "cokenler", name: "Çöken servisler",
                command: "systemctl --failed --no-pager || echo 'systemd yok'", builtin: true),
        Snippet(id: "buyukler", name: "En çok yer kaplayan klasörler (/var)",
                command: "du -xh /var 2>/dev/null | sort -rh | head -n 15", asRoot: true, builtin: true),
        Snippet(id: "girisler", name: "Son girişler",
                command: "last -n 15 2>/dev/null || echo 'last komutu yok'", builtin: true),
        Snippet(id: "portlar", name: "Dinlenen portlar",
                command: "ss -tulpn 2>/dev/null || netstat -tulpn", asRoot: true, builtin: true),
        Snippet(id: "docker", name: "Docker konteynerleri",
                command: "docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'", builtin: true),
        Snippet(id: "nginx-test", name: "Nginx ayarlarını dene",
                command: "nginx -t", asRoot: true, builtin: true),
        Snippet(id: "nginx-reload", name: "Nginx'i yeniden yükle",
                command: "nginx -t && systemctl reload nginx && echo 'Nginx yeniden yüklendi'",
                asRoot: true, changesSystem: true, builtin: true),
        Snippet(id: "log-temizle", name: "Eski günlükleri temizle (7 günden eski)",
                command: "journalctl --vacuum-time=7d", asRoot: true, changesSystem: true, builtin: true),
    ]
}

/// Kullanıcının kendi komutları: ~/Library/Application Support/SSHManager/komutlar.json
public final class SnippetStore {
    public static let shared = SnippetStore()

    public private(set) var custom: [Snippet] = []
    private let fileURL: URL

    public init(fileURL: URL = Paths.dataDirectory.appendingPathComponent("komutlar.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Snippet].self, from: data) {
            custom = list
        }
    }

    public var all: [Snippet] { Snippet.builtins + custom }

    public func save(_ snippet: Snippet) throws {
        var s = snippet
        s.builtin = false
        if let i = custom.firstIndex(where: { $0.id == s.id }) { custom[i] = s } else { custom.append(s) }
        try persist()
    }

    public func remove(id: String) throws {
        custom.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(custom).write(to: fileURL, options: .atomic)
    }
}
