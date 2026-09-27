import AppKit
import SSHManagerKit
import UserNotifications

/// Sunucuları arka planda düzenli kontrol eder (disk, bellek, yük, çöken servis, güncelleme, yeniden başlatma).
/// Kontroller sessizdir: hiçbir pencere açmaz. Bildirim sadece durum değişince gelir.
final class HealthMonitor: ObservableObject {
    static let shared = HealthMonitor()

    @Published private(set) var reports: [UUID: HealthReport] = [:]
    @Published private(set) var checking: Set<UUID> = []

    /// Durum değişince (menü simgesi ve menü yeniden çizilsin diye).
    var onChange: (() -> Void)?

    private var timer: Timer?
    private let queue = BatchQueue(limit: 4)
    private let fileURL = Paths.dataDirectory.appendingPathComponent("saglik.json")

    private init() {
        load()
    }

    // MARK: - Zamanlama

    func start() {
        reschedule()
        // Açılıştan kısa süre sonra ilk kontrol (uygulama açılışını yavaşlatmasın).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if Settings.healthInterval > 0 { self?.checkAll() }
        }
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        let minutes = Settings.healthInterval
        guard minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            self?.checkAll()
        }
        timer?.tolerance = 30
    }

    // MARK: - Kontrol

    func checkAll() {
        ServerStore.shared.load()
        for server in ServerStore.shared.servers { check(server) }
    }

    func check(_ server: Server) {
        guard !checking.contains(server.id) else { return }
        checking.insert(server.id)
        queue.add { [weak self] done in
            let run = RemoteRun(server: server)
            run.start(command: RemoteScripts.health, asRoot: false, mode: .silent, timeout: 45) { result in
                self?.checking.remove(server.id)
                let report = result.output.contains("BD_OK=1")
                    ? HealthReport.from(output: result.output)
                    : HealthReport.failure(output: result.timedOut ? "timed out" : result.output)
                self?.store(report, for: server)
                done()
            }
        }
    }

    // MARK: - Sonuçlar

    func level(for server: Server) -> HealthLevel {
        reports[server.id]?.evaluation.level ?? .unknown
    }

    /// Menü simgesi için: en kötü durumdaki sunucular.
    var worst: (level: HealthLevel, count: Int) {
        let ids = Set(ServerStore.shared.servers.map(\.id))
        let levels = reports.filter { ids.contains($0.key) }.values.map { $0.evaluation.level }
        let top = levels.max() ?? .unknown
        return (top, levels.filter { $0 == top }.count)
    }

    private func store(_ report: HealthReport, for server: Server) {
        let before = reports[server.id]?.evaluation
        reports[server.id] = report
        save()
        notifyIfChanged(server: server, before: before, after: report.evaluation)
        onChange?()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: HealthReport].self, from: data) else { return }
        reports = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: reports.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: - Bildirimler

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfChanged(server: Server, before: (level: HealthLevel, issues: [String])?, after: (level: HealthLevel, issues: [String])) {
        guard Settings.healthNotifications else { return }
        let old = before?.level ?? .unknown
        let new = after.level
        let title: String
        let body: String
        if new == .bad, old != .bad || before?.issues.first != after.issues.first {
            title = "\(server.name): sorun var"
            body = after.issues.prefix(2).joined(separator: " · ")
        } else if new == .warn, old == .ok || old == .unknown, before != nil {
            title = "\(server.name): dikkat"
            body = after.issues.prefix(2).joined(separator: " · ")
        } else if old == .bad, new == .ok || new == .warn {
            title = "\(server.name): düzeldi"
            body = new == .ok ? "Her şey yolunda." : after.issues.prefix(2).joined(separator: " · ")
        } else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = new == .bad ? .default : nil
        let request = UNNotificationRequest(identifier: "saglik-\(server.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
