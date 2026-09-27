import Foundation

enum TerminalChoice: String, CaseIterable {
    case terminal, iterm

    var title: String {
        switch self {
        case .terminal: return "Terminal (macOS)"
        case .iterm: return "iTerm2"
        }
    }
}

/// Kullanıcı tercihleri. Menü uygulaması ile askpass/CLI ayrı süreçler olduğu için
/// sabit adlı ortak bir UserDefaults alanı kullanılır.
enum Settings {
    private static let defaults = UserDefaults(suiteName: "com.yusuf.sshmanager.ayarlar")!

    static var terminal: TerminalChoice {
        get { TerminalChoice(rawValue: defaults.string(forKey: "terminal") ?? "") ?? .terminal }
        set { defaults.set(newValue.rawValue, forKey: "terminal") }
    }

    /// Terminal.app'te yeni pencere yerine sekme aç (Erişilebilirlik izni gerektirir).
    static var terminalTabs: Bool {
        get { defaults.object(forKey: "terminalTabs") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "terminalTabs") }
    }

    /// Sağlık kontrolü aralığı (dakika). 0 = kapalı.
    static var healthInterval: Int {
        get { defaults.object(forKey: "healthInterval") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "healthInterval") }
    }

    /// Sunucu durumu değişince bildirim göster.
    static var healthNotifications: Bool {
        get { defaults.object(forKey: "healthNotifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "healthNotifications") }
    }

    /// Kayıtlı parola kullanılmadan önce Touch ID (ya da Mac parolası) iste.
    static var requireTouchID: Bool {
        get { defaults.bool(forKey: "requireTouchID") }
        set { defaults.set(newValue, forKey: "requireTouchID") }
    }
}

enum AppPaths {
    /// Uygulamanın gerçek çalıştırılabilir dosyası (sshm bağlantısı üzerinden çağrılsa bile).
    static var executable: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SSHManager", isDirectory: true)
    }
}
