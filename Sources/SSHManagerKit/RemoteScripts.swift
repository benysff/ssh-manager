import Foundation

/// Sunucuda çalıştırılan betikler ve çıktılarının okunması.
///
/// Betikler POSIX `sh` ile yazıldı (Ubuntu/Debian başta olmak üzere her Linux'ta çalışır) ve sonuçları
/// `BD_ANAHTAR=değer` satırları halinde basar; uygulama bu satırları okur, geri kalan çıktıyı gösterir.
public enum RemoteScripts {

    // MARK: - Sağlık kontrolü (yetki gerektirmez)

    public static let health = #"""
    export LC_ALL=C
    echo "BD_OK=1"
    echo "BD_OS=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -s)}" )"
    echo "BD_UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
    if [ -r /proc/loadavg ]; then read l1 l5 l15 rest < /proc/loadavg; echo "BD_LOAD=$l1"; fi
    echo "BD_CPUS=$(nproc 2>/dev/null || echo 1)"
    awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{if (t > 0) printf "BD_MEM=%d\n", (t-a)*100/t}' /proc/meminfo 2>/dev/null
    df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {p=$5; sub("%","",p); p+=0; if (mp == "" || p > m || (p == m && length($6) < length(mp))) {m=p; mp=$6}} END {if (mp != "") printf "BD_DISK=%d\nBD_DISK_MOUNT=%s\n", m, mp}'
    if [ -f /var/run/reboot-required ]; then echo "BD_REBOOT=1"; else echo "BD_REBOOT=0"; fi
    if [ -x /usr/lib/update-notifier/apt-check ]; then
      # apt-check sayıları stderr'e "toplam;güvenlik" diye yazar; araya Python uyarıları karışabilir: son satırı al.
      r=$(/usr/lib/update-notifier/apt-check 2>&1 >/dev/null | tail -n 1)
      case "$r" in [0-9]*\;[0-9]*) echo "BD_UPDATES=${r%%;*}"; echo "BD_SECURITY=${r##*;}";; esac
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      echo "BD_FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | grep -c .)"
    fi
    """#

    // MARK: - Güncellemeler (yönetici yetkisi ister)

    /// Paket listesini tazeler ve bekleyen güncellemeleri sayar. Hiçbir şey kurmaz.
    public static let updateCheck = #"""
    export LC_ALL=C DEBIAN_FRONTEND=noninteractive
    if ! command -v apt-get >/dev/null 2>&1; then echo "BD_UNSUPPORTED=1"; exit 0; fi
    if ! log=$(apt-get update -q 2>&1); then
      printf '%s\n' "$log" | tail -n 5; echo "BD_UPDATE_FAILED=1"
    fi
    list=$(apt list --upgradable 2>/dev/null | grep /)
    if [ -n "$list" ]; then
      echo "BD_TOTAL=$(printf '%s\n' "$list" | grep -c /)"
      echo "BD_SECURITY=$(printf '%s\n' "$list" | grep -c -- '-security')"
    else
      echo "BD_TOTAL=0"; echo "BD_SECURITY=0"
    fi
    if [ -f /var/run/reboot-required ]; then echo "BD_REBOOT=1"; else echo "BD_REBOOT=0"; fi
    if command -v unattended-upgrade >/dev/null 2>&1; then echo "BD_UNATTENDED=1"; else echo "BD_UNATTENDED=0"; fi
    printf '%s\n' "$list" | head -n 300 | sed -n 's/^\([^/]*\)\/.*/BD_PKG=\1/p'
    """#

    /// Güncellemeleri kurar. `apt-get upgrade`: paket silmez, yeni paket kurmaz (en güvenli tür).
    /// Servisler kendiliğinden yeniden başlatılmaz (needrestart sadece listeler).
    public static func updateApply(securityOnly: Bool) -> String {
        let run = securityOnly
            ? #"""
            if command -v unattended-upgrade >/dev/null 2>&1; then
              unattended-upgrade -v
            else
              echo "Bu sunucuda 'sadece güvenlik' için unattended-upgrades yok. Kurmak için: apt-get install unattended-upgrades"
              exit 3
            fi
            """#
            : #"apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade"#
        return """
        export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
        \(run)
        rc=$?
        if [ -f /var/run/reboot-required ]; then echo "BD_REBOOT=1"; else echo "BD_REBOOT=0"; fi
        exit $rc
        """
    }

    /// 1 dakika sonra yeniden başlatır (bu sürede iptal edilebilir).
    public static let rebootScheduled = #"shutdown -r +1 "SSHManager: guncelleme sonrasi yeniden baslatma" && echo "BD_REBOOT_SCHEDULED=1""#
    public static let rebootCancel = #"shutdown -c && echo "BD_REBOOT_CANCELLED=1""#

    // MARK: - Yönetici yetkisi (sudo) sarmalayıcısı

    /// Betiği yönetici olarak çalıştıran uzak komut.
    ///
    /// Uygulama stdin'e her zaman tek bir satır yazar (kayıtlı parola ya da boş satır). Sarmalayıcı:
    /// root ise ve parolasız sudo varsa o satırı okuyup atar; yoksa sudo parolayı stdin'den okur.
    /// Böylece parola ne komut satırında ne ekranda görünür ve tek SSH bağlantısı yeter.
    public static func asRoot(_ script: String) -> String {
        let wrapper = #"""
        if [ "$(id -u)" -eq 0 ]; then IFS= read -r _ || true; exec sh -c "$1"; fi
        if sudo -n true 2>/dev/null; then IFS= read -r _ || true; exec sudo -n sh -c "$1"; fi
        exec sudo -S -p '' sh -c "$1"
        """#
        return "sh -c " + SSHCommand.shellQuote(wrapper) + " sshmanager " + SSHCommand.shellQuote(script)
    }

    /// sudo parolası yanlış ya da eksik mi?
    public static func sudoPasswordRejected(_ output: String) -> Bool {
        let o = output.lowercased()
        return o.contains("incorrect password") || o.contains("a password is required")
            || o.contains("sorry, try again") || o.contains("no password was provided")
    }

    // MARK: - Çıktı okuma

    /// `BD_ANAHTAR=değer` satırlarını toplar; aynı anahtar tekrar ederse hepsi listeye eklenir.
    public static func parse(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("BD_"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 3)..<eq])
            result[key, default: []].append(String(line[line.index(after: eq)...]))
        }
        return result
    }

    /// Kullanıcıya gösterilecek çıktı: `BD_` satırları çıkarılmış hali.
    public static func visibleOutput(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("BD_") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sağlık raporu

public enum HealthLevel: String, Codable, Comparable {
    case unknown, ok, warn, bad

    private var rank: Int { ["unknown": 0, "ok": 1, "warn": 2, "bad": 3][rawValue]! }
    public static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rank < b.rank }
}

public struct HealthReport: Codable, Equatable {
    public var checkedAt: Date
    public var reachable: Bool
    public var error: String?
    /// Ulaşılamadıysa neden: "network" (sunucu gerçekten yanıt vermiyor), "auth" / "hostkey" (arka planda giriş izni yok).
    public var errorKind: String?
    public var os: String?
    public var uptime: Int?
    public var load: Double?
    public var cpus: Int?
    public var memory: Int?
    public var disk: Int?
    public var diskMount: String?
    public var rebootRequired: Bool?
    public var updates: Int?
    public var securityUpdates: Int?
    public var failedServices: Int?

    public init(checkedAt: Date = Date(), reachable: Bool, error: String? = nil) {
        self.checkedAt = checkedAt
        self.reachable = reachable
        self.error = error
    }

    /// Sağlık betiğinin çıktısından rapor üretir.
    public static func from(output: String, at date: Date = Date()) -> HealthReport {
        let kv = RemoteScripts.parse(output)
        func str(_ k: String) -> String? { kv[k]?.last.flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ k: String) -> Int? { str(k).flatMap { Int($0) } }
        guard kv["OK"] != nil else { return failure(output: output, at: date) }
        var r = HealthReport(checkedAt: date, reachable: true)
        r.os = str("OS")
        r.uptime = int("UPTIME")
        r.load = str("LOAD").flatMap { Double($0) }
        r.cpus = int("CPUS")
        r.memory = int("MEM")
        r.disk = int("DISK")
        r.diskMount = str("DISK_MOUNT")
        r.rebootRequired = str("REBOOT").map { $0 == "1" }
        r.updates = int("UPDATES")
        r.securityUpdates = int("SECURITY")
        r.failedServices = int("FAILED")
        return r
    }

    /// ssh başarısız olduğunda nedeni sade dille.
    public static func failure(output: String, at date: Date = Date()) -> HealthReport {
        let o = output.lowercased()
        var r = HealthReport(checkedAt: date, reachable: false)
        if o.contains("host key verification failed") || o.contains("identification has changed") {
            r.errorKind = "hostkey"
            r.error = "Sunucunun parmak izi onaylanmamış: menüden bir kez bağlan."
        } else if o.contains("permission denied") || o.contains("too many authentication failures") {
            r.errorKind = "auth"
            r.error = "Arka planda giriş yapılamadı: menüden bir kez bağlan (Anahtar Zinciri sorarsa \"Her Zaman İzin Ver\")."
        } else if o.contains("could not resolve hostname") || o.contains("nodename nor servname") {
            r.errorKind = "network"
            r.error = "Sunucu adresi bulunamadı."
        } else if o.contains("connection refused") {
            r.errorKind = "network"
            r.error = "Sunucu bağlantıyı reddetti (SSH kapalı olabilir)."
        } else if o.contains("timed out") || o.contains("no route to host") || o.contains("network is unreachable")
                    || o.contains("connection closed") || o.contains("connection reset") {
            r.errorKind = "network"
            r.error = "Sunucuya ulaşılamıyor (zaman aşımı)."
        } else {
            r.errorKind = "network"
            r.error = RemoteScripts.visibleOutput(output).split(separator: "\n").last.map(String.init)
                ?? "Sunucu beklenen cevabı vermedi."
        }
        return r
    }

    /// Genel durum ve sade dille sorun listesi (en önemlisi başta).
    /// Arka planda giriş izni olmaması sunucunun bozuk olduğu anlamına gelmez: gri (bilinmiyor) gösterilir.
    public var evaluation: (level: HealthLevel, issues: [String]) {
        guard reachable else {
            let level: HealthLevel = errorKind == "network" ? .bad : .unknown
            return (level, [error ?? "Ulaşılamıyor."])
        }
        var bad: [String] = []
        var warn: [String] = []
        if let d = disk {
            let where_ = diskMount.map { " (\($0))" } ?? ""
            if d >= 90 { bad.append("Disk %\(d) dolu\(where_)") } else if d >= 80 { warn.append("Disk %\(d) dolu\(where_)") }
        }
        if let f = failedServices, f > 0 { bad.append("\(f) servis çökmüş") }
        if let m = memory, m >= 95 { warn.append("Bellek %\(m) dolu") }
        if let l = load, let c = cpus, c > 0, l / Double(c) >= 2 { warn.append("İşlemci yükü yüksek (\(String(format: "%.1f", l)))") }
        if let s = securityUpdates, s > 0 { warn.append("\(s) güvenlik güncellemesi bekliyor") }
        if rebootRequired == true { warn.append("Yeniden başlatma bekliyor") }
        let level: HealthLevel = !bad.isEmpty ? .bad : !warn.isEmpty ? .warn : .ok
        return (level, bad + warn)
    }
}

// MARK: - Güncelleme kontrolü sonucu

public struct UpdateCheck: Equatable {
    public var supported: Bool
    public var refreshFailed: Bool
    public var total: Int
    public var security: Int
    public var rebootRequired: Bool
    public var hasUnattended: Bool
    public var packages: [String]

    public static func from(output: String) -> UpdateCheck {
        let kv = RemoteScripts.parse(output)
        func int(_ k: String) -> Int { kv[k]?.last.flatMap { Int($0) } ?? 0 }
        return UpdateCheck(
            supported: kv["UNSUPPORTED"] == nil,
            refreshFailed: kv["UPDATE_FAILED"] != nil,
            total: int("TOTAL"),
            security: int("SECURITY"),
            rebootRequired: kv["REBOOT"]?.last == "1",
            hasUnattended: kv["UNATTENDED"]?.last == "1",
            packages: kv["PKG"] ?? []
        )
    }
}
