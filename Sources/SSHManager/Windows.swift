import AppKit
import LocalAuthentication
import SSHManagerKit
import SwiftUI

// MARK: - Ortak

/// Menüden tetiklenen işler (AppDelegate doldurur).
enum AppActions {
    static var connect: ((Server) -> Void)?
}

/// SwiftUI pencerelerini açar; aynı pencere açıksa öne getirir.
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: NSSize, replace: Bool = false, content: () -> V) {
        if let w = windows[id], w.isVisible, !replace {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        windows[id]?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
        w.title = title
        w.styleMask.insert([.resizable, .closable, .miniaturizable])
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

func levelColor(_ level: HealthLevel) -> Color {
    switch level {
    case .ok: return .green
    case .warn: return .orange
    case .bad: return .red
    case .unknown: return .gray
    }
}

/// Touch ID koruması açıksa, işten önce bir kez kimlik doğrula (onay bir süre bütün sunuculara yeter).
func confirmIdentityIfNeeded(_ reason: String) async -> Bool {
    guard Settings.requireTouchID, !IdentityGate.isFresh else { return true }
    let ctx = LAContext()
    var err: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
    guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false else { return false }
    IdentityGate.confirmed()
    return true
}

/// Toplu işten önce: kimliği bir kez doğrula, kasayı bir kez aç (eski tek tek kayıtları da şimdi, sırayla taşı).
/// Böylece izin pencereleri iş sırasında sunucu sunucu, üst üste açılmaz.
@MainActor
func prepareBatch(_ servers: [Server], reason: String) async -> Bool {
    guard await confirmIdentityIfNeeded(reason) else { return false }
    PasswordVault.unlock(for: servers)
    return true
}

private let trLocale = Locale(identifier: "tr_TR")

/// Görünüm içi küçük durumlar için. `@State` macOS 27 SDK'sında makro; Komut Satırı Araçları'nda
/// (sadece xcode-select --install ile) makro eklentisi olmadığından derlenmiyor. Bu kutular makrosuz çalışır.
final class ViewState<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

/// Canlı (kırmızı temalı) sunucularda sistem değiştiren işlerden önce "EVET" yazdıran onay.
struct LiveServerConfirm: ViewModifier {
    @Binding var isPresented: Bool
    let servers: [Server]
    let action: () -> Void
    @StateObject private var typed = ViewState("")

    func body(content: Content) -> some View {
        content.alert("Canlı sunucu!", isPresented: $isPresented) {
            TextField("EVET", text: $typed.value)
            Button("Vazgeç", role: .cancel) { typed.value = "" }
            Button("Devam et", role: .destructive) {
                if typed.value.trimmingCharacters(in: .whitespaces).uppercased(with: trLocale) == "EVET" { action() }
                typed.value = ""
            }
        } message: {
            Text("Şu sunucular canlı olarak işaretli: \(servers.map(\.name).joined(separator: ", ")).\nDevam etmek için EVET yaz.")
        }
    }
}

// MARK: - Sağlık panosu

struct HealthDashboardView: View {
    @ObservedObject private var monitor = HealthMonitor.shared
    @StateObject private var selectionBox = ViewState(Set<UUID>())
    private var selection: Set<UUID> { selectionBox.value }

    private struct Row: Identifiable {
        let id: UUID
        let server: Server
        let report: HealthReport?
        var level: HealthLevel { report?.evaluation.level ?? .unknown }
    }

    private var rows: [Row] {
        ServerStore.shared.servers
            .map { Row(id: $0.id, server: $0, report: monitor.reports[$0.id]) }
            .sorted { ($0.level, $1.server.name) > ($1.level, $0.server.name) }
    }

    private var summary: String {
        let levels = rows.map(\.level)
        let bad = levels.filter { $0 == .bad }.count, warn = levels.filter { $0 == .warn }.count
        if bad + warn == 0 { return "\(rows.count) sunucu · hepsi yolunda" }
        return "\(rows.count) sunucu · \(bad) sorunlu · \(warn) dikkat"
    }

    private func servers(_ ids: Set<UUID>) -> [Server] { rows.filter { ids.contains($0.id) }.map(\.server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(summary).font(.headline)
                if !monitor.checking.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                Button { monitor.checkAll() } label: { Label("Şimdi kontrol et", systemImage: "arrow.clockwise") }
                Button { showUpdates(servers(selection).isEmpty ? ServerStore.shared.servers : servers(selection)) } label: {
                    Label("Güncellemeler…", systemImage: "arrow.down.circle")
                }
                Button { showRunner(servers(selection)) } label: { Label("Komut çalıştır…", systemImage: "terminal") }
            }
            .padding(12)
            Divider()
            Table(rows, selection: $selectionBox.value) {
                TableColumn("Sunucu") { row in
                    HStack(spacing: 7) {
                        Circle().fill(levelColor(row.level)).frame(width: 9, height: 9)
                        Text(row.server.name).fontWeight(.medium)
                        if monitor.checking.contains(row.id) { ProgressView().controlSize(.mini) }
                    }
                }
                .width(min: 150, ideal: 190)
                TableColumn("Durum") { row in
                    let issues = row.report?.evaluation.issues ?? []
                    Text(row.report == nil ? "Henüz kontrol edilmedi" : issues.isEmpty ? "Sağlıklı" : issues.joined(separator: " · "))
                        .foregroundStyle(row.level == .ok ? .secondary : levelColor(row.level))
                        .help(issues.joined(separator: "\n"))
                }
                .width(min: 180, ideal: 300)
                TableColumn("Disk") { row in Text(row.report?.disk.map { "%\($0)" } ?? "—").monospacedDigit() }.width(55)
                TableColumn("Bellek") { row in Text(row.report?.memory.map { "%\($0)" } ?? "—").monospacedDigit() }.width(55)
                TableColumn("Yük") { row in Text(row.report?.load.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit() }.width(50)
                TableColumn("Güncelleme") { row in
                    if let u = row.report?.updates {
                        Text(u == 0 ? "Güncel" : "\(u) (\(row.report?.securityUpdates ?? 0) güvenlik)")
                    } else { Text("—") }
                }
                .width(min: 80, ideal: 120)
                TableColumn("Sistem") { row in Text(row.report?.os ?? "—").foregroundStyle(.secondary) }.width(min: 90, ideal: 150)
                TableColumn("Son kontrol") { row in
                    if let d = row.report?.checkedAt { Text(d, style: .relative) + Text(" önce") } else { Text("—") }
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Bağlan") { servers(ids).first.map { AppActions.connect?($0) } }
                Button("Şimdi kontrol et") { servers(ids).forEach { monitor.check($0) } }
                Divider()
                Button("Komut çalıştır…") { showRunner(servers(ids)) }
                Button("Güncellemeler…") { showUpdates(servers(ids)) }
            } primaryAction: { ids in
                servers(ids).first.map { AppActions.connect?($0) }
            }
            Divider()
            Text("Kontroller arka planda sessizce yapılır (\(Settings.healthInterval > 0 ? "her \(Settings.healthInterval) dk" : "kapalı")); hiçbir pencere açılmaz. Çift tıkla: bağlan.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 760, minHeight: 320)
    }
}

func showHealth() {
    WindowPresenter.shared.show("saglik", title: "Sağlık panosu", size: NSSize(width: 980, height: 460)) { HealthDashboardView() }
}

// MARK: - Komut çalıştır

final class CommandRunnerModel: ObservableObject {
    enum Status { case waiting, running, ok, failed }

    struct RunState {
        var status: Status = .waiting
        var output = ""
        var duration: TimeInterval?
        var exitCode: Int32?
    }

    @Published var snippets: [Snippet] = SnippetStore.shared.all
    @Published var selectedSnippet: String?
    @Published var command = ""
    @Published var asRoot = false
    @Published var changesSystem = false
    @Published var targets: Set<UUID>
    @Published var results: [UUID: RunState] = [:]
    @Published var running = false
    @Published var error: String?
    @Published var confirmLive = false
    @Published var naming = false
    @Published var newName = ""

    let servers: [Server]
    private var runs: [RemoteRun] = []

    init(targets: [Server]) {
        servers = ServerStore.shared.servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.targets = Set(targets.map(\.id))
    }

    func pick(_ id: String?) {
        selectedSnippet = id
        guard let s = snippets.first(where: { $0.id == id }) else { return }
        command = s.command
        asRoot = s.asRoot
        changesSystem = s.changesSystem
    }

    var liveTargets: [Server] { servers.filter { targets.contains($0.id) && $0.theme == .red } }
    var needsLiveConfirm: Bool { !liveTargets.isEmpty && (changesSystem || asRoot) }
    var canRun: Bool { !running && !targets.isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func run() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = servers.filter { targets.contains($0.id) }
        guard !cmd.isEmpty, !chosen.isEmpty else { return }
        Task { @MainActor in
            guard await prepareBatch(chosen, reason: "sunucularda komut çalıştırmak") else { return }
            self.start(cmd, on: chosen)
        }
    }

    private func start(_ cmd: String, on chosen: [Server]) {
        running = true
        results = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, RunState()) })
        runs = []
        let queue = BatchQueue(limit: 4)
        var remaining = chosen.count
        for server in chosen {
            queue.add { [weak self] done in
                guard let self = self else { return done() }
                let run = RemoteRun(server: server)
                self.runs.append(run)
                self.results[server.id]?.status = .running
                run.start(command: cmd, asRoot: self.asRoot, mode: .interactive, timeout: 900, onOutput: { text in
                    self.results[server.id]?.output += text
                }) { result in
                    var s = self.results[server.id] ?? RunState()
                    s.status = result.ok ? .ok : .failed
                    s.duration = result.duration
                    s.exitCode = result.exitCode
                    if result.timedOut { s.output += "\n(zaman aşımı: 15 dakika)" }
                    if s.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        s.output = result.ok ? "(çıktı yok)" : RemoteScripts.visibleOutput(result.output)
                    }
                    self.results[server.id] = s
                    remaining -= 1
                    if remaining == 0 { self.running = false }
                    done()
                }
            }
        }
    }

    func stop() {
        runs.forEach { $0.cancel() }
    }

    func saveSnippet(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var s = snippets.first(where: { $0.id == selectedSnippet && !$0.builtin }) ?? Snippet(name: n, command: command)
        s.name = n
        s.command = command
        s.asRoot = asRoot
        s.changesSystem = changesSystem
        do {
            try SnippetStore.shared.save(s)
            snippets = SnippetStore.shared.all
            selectedSnippet = s.id
        } catch { self.error = error.localizedDescription }
    }

    func deleteSnippet(_ id: String) {
        try? SnippetStore.shared.remove(id: id)
        snippets = SnippetStore.shared.all
        if selectedSnippet == id { selectedSnippet = nil }
    }

    func copyAll() {
        let text = servers.filter { results[$0.id] != nil }.map { s in
            let r = results[s.id]!
            return "=== \(s.name) (\(r.status == .ok ? "tamam" : "hata \(r.exitCode ?? -1)")) ===\n\(r.output)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct CommandRunnerView: View {
    @StateObject var model: CommandRunnerModel

    var body: some View {
        HSplitView {
            List(selection: Binding(get: { model.selectedSnippet }, set: { model.pick($0) })) {
                Section("Hazır komutlar") {
                    ForEach(model.snippets.filter(\.builtin)) { s in snippetRow(s) }
                }
                Section("Benim komutlarım") {
                    ForEach(model.snippets.filter { !$0.builtin }) { s in
                        snippetRow(s).contextMenu { Button("Sil", role: .destructive) { model.deleteSnippet(s.id) } }
                    }
                    if !model.snippets.contains(where: { !$0.builtin }) {
                        Text("Aşağıya bir komut yazıp “Kaydet” de.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                Text("Komut").font(.headline)
                TextEditor(text: $model.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack(spacing: 16) {
                    Toggle("Yönetici (sudo) olarak", isOn: $model.asRoot)
                    Toggle("Sistemi değiştirir", isOn: $model.changesSystem)
                        .help("Canlı (kırmızı) sunucularda çalıştırmadan önce onay istenir.")
                    Spacer()
                    Button("Kaydet…") { model.newName = model.snippets.first { $0.id == model.selectedSnippet && !$0.builtin }?.name ?? ""; model.naming = true }
                        .disabled(model.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text("Sunucular").font(.headline)
                    Spacer()
                    Button("Hepsi") { model.targets = Set(model.servers.map(\.id)) }.buttonStyle(.link)
                    Button("Hiçbiri") { model.targets = [] }.buttonStyle(.link)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(model.servers) { s in
                            Toggle(isOn: Binding(get: { model.targets.contains(s.id) },
                                                 set: { on in if on { model.targets.insert(s.id) } else { model.targets.remove(s.id) } })) {
                                HStack(spacing: 5) {
                                    Circle().fill(levelColor(HealthMonitor.shared.level(for: s))).frame(width: 7, height: 7)
                                    Text(s.name).lineLimit(1)
                                    if s.theme == .red { Text("CANLI").font(.caption2.bold()).foregroundStyle(.red) }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 50, maxHeight: 120)
                HStack {
                    if model.running {
                        Button(role: .destructive) { model.stop() } label: { Label("Durdur", systemImage: "stop.fill") }
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            if model.needsLiveConfirm { model.confirmLive = true } else { model.run() }
                        } label: { Label("Çalıştır (\(model.targets.count) sunucu)", systemImage: "play.fill") }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!model.canRun)
                    }
                    Spacer()
                    if !model.results.isEmpty { Button("Çıktıları kopyala") { model.copyAll() } }
                }
                Divider()
                List {
                    ForEach(model.servers.filter { model.results[$0.id] != nil }) { s in
                        let r = model.results[s.id]!
                        DisclosureGroup {
                            Text(r.output.isEmpty ? "…" : r.output)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                statusIcon(r.status)
                                Text(s.name).fontWeight(.medium)
                                Spacer()
                                if let d = r.duration { Text(String(format: "%.1f sn", d)).foregroundStyle(.secondary).monospacedDigit() }
                                if r.status == .failed, let c = r.exitCode { Text("kod \(c)").foregroundStyle(.red) }
                            }
                        }
                    }
                }
                .frame(minHeight: 140)
            }
            .padding(12)
            .frame(minWidth: 520)
        }
        .frame(minWidth: 780, minHeight: 560)
        .modifier(LiveServerConfirm(isPresented: $model.confirmLive, servers: model.liveTargets) { model.run() })
        .alert("Komutu kaydet", isPresented: $model.naming) {
            TextField("Ad (ör. Uygulamayı yeniden başlat)", text: $model.newName)
            Button("Vazgeç", role: .cancel) {}
            Button("Kaydet") { model.saveSnippet(name: model.newName) }
        }
    }

    private func snippetRow(_ s: Snippet) -> some View {
        HStack(spacing: 6) {
            Text(s.name).lineLimit(1)
            Spacer()
            if s.asRoot { Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Yönetici olarak çalışır") }
            if s.changesSystem { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Sistemi değiştirir") }
        }
        .tag(Optional(s.id))
    }

    @ViewBuilder private func statusIcon(_ s: CommandRunnerModel.Status) -> some View {
        switch s {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

func showRunner(_ targets: [Server]) {
    WindowPresenter.shared.show("komut", title: "Komut çalıştır", size: NSSize(width: 900, height: 640), replace: true) {
        CommandRunnerView(model: CommandRunnerModel(targets: targets))
    }
}

// MARK: - Güncellemeler

final class UpdatesModel: ObservableObject {
    enum State: Equatable { case idle, checking, checked, updating, updated, failed(String), unsupported }

    struct Row: Identifiable {
        let id: UUID
        let server: Server
        var state: State = .idle
        var check: UpdateCheck?
        var log = ""
        var rebootScheduled = false
        var busy: Bool { state == .checking || state == .updating }
    }

    @Published var rows: [Row]
    @Published var selected: Set<UUID>
    @Published var securityOnly = false
    @Published var showLog: Set<UUID> = []
    @Published var confirmLive = false
    @Published var confirmUpdate = false
    @Published var rebootTarget: UUID?

    init(servers: [Server]) {
        let all = ServerStore.shared.servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        rows = all.map { Row(id: $0.id, server: $0) }
        selected = Set(servers.map(\.id))
    }

    var busy: Bool { rows.contains(where: \.busy) }
    var selectedServers: [Server] { rows.filter { selected.contains($0.id) }.map(\.server) }
    var liveSelected: [Server] { selectedServers.filter { $0.theme == .red } }
    var updatable: [Row] { rows.filter { selected.contains($0.id) && ($0.check?.total ?? 0) > 0 } }

    private func index(_ id: UUID) -> Int? { rows.firstIndex { $0.id == id } }

    func checkSelected() {
        let chosen = selectedServers
        Task { @MainActor in
            guard await prepareBatch(chosen, reason: "sunuculardaki güncellemeleri kontrol etmek") else { return }
            let queue = BatchQueue(limit: 4)
            for s in chosen {
                guard let i = self.index(s.id) else { continue }
                self.rows[i].state = .checking
                self.rows[i].log = ""
                queue.add { done in
                    RemoteRun(server: s).start(command: RemoteScripts.updateCheck, asRoot: true, mode: .interactive, timeout: 300) { result in
                        guard let i = self.index(s.id) else { return done() }
                        let c = UpdateCheck.from(output: result.output)
                        if !c.supported {
                            self.rows[i].state = .unsupported
                        } else if !result.ok {
                            self.rows[i].state = .failed(Self.explain(result))
                        } else {
                            self.rows[i].check = c
                            self.rows[i].state = .checked
                        }
                        self.rows[i].log = RemoteScripts.visibleOutput(result.output)
                        done()
                    }
                }
            }
        }
    }

    func updateSelected() {
        let chosen = updatable.map(\.server)
        let securityOnly = self.securityOnly
        Task { @MainActor in
            guard await prepareBatch(chosen, reason: "sunucuları güncellemek") else { return }
            let queue = BatchQueue(limit: 3)
            for s in chosen {
                guard let i = self.index(s.id) else { continue }
                self.rows[i].state = .updating
                self.rows[i].log = ""
                self.showLog.insert(s.id)
                queue.add { done in
                    RemoteRun(server: s).start(command: RemoteScripts.updateApply(securityOnly: securityOnly), asRoot: true,
                                               mode: .interactive, timeout: 3600, onOutput: { text in
                        if let i = self.index(s.id) { self.rows[i].log += text }
                    }) { result in
                        guard let i = self.index(s.id) else { return done() }
                        let reboot = RemoteScripts.parse(result.output)["REBOOT"]?.last == "1"
                        self.rows[i].state = result.ok ? .updated : .failed(Self.explain(result))
                        if result.ok { self.showLog.remove(s.id) }
                        var c = self.rows[i].check ?? UpdateCheck.from(output: "")
                        c.rebootRequired = reboot
                        if result.ok { c.total = 0; c.security = 0; c.packages = [] }
                        self.rows[i].check = c
                        HealthMonitor.shared.check(s)
                        done()
                    }
                }
            }
        }
    }

    func reboot(_ id: UUID, cancel: Bool = false) {
        guard let i = index(id) else { return }
        let s = rows[i].server
        RemoteRun(server: s).start(command: cancel ? RemoteScripts.rebootCancel : RemoteScripts.rebootScheduled,
                                   asRoot: true, mode: .interactive, timeout: 60) { result in
            guard let i = self.index(id) else { return }
            if result.ok {
                self.rows[i].rebootScheduled = !cancel
            } else {
                self.rows[i].log = RemoteScripts.visibleOutput(result.output)
                self.showLog.insert(id)
            }
        }
    }

    static func explain(_ r: RemoteRun.Result) -> String {
        if r.timedOut { return "Zaman aşımı" }
        if RemoteScripts.sudoPasswordRejected(r.output) { return "sudo parolası kabul edilmedi" }
        let f = HealthReport.failure(output: r.output)
        if f.errorKind != "network" || r.exitCode == 255 { return f.error ?? "Bağlanılamadı" }
        return "Hata (kod \(r.exitCode))"
    }
}

struct UpdatesView: View {
    @StateObject var model: UpdatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.checkSelected() } label: { Label("Güncellemeleri kontrol et", systemImage: "magnifyingglass") }
                    .disabled(model.busy || model.selected.isEmpty)
                Toggle("Sadece güvenlik güncellemeleri", isOn: $model.securityOnly)
                Spacer()
                Button {
                    if !model.liveSelected.filter({ s in model.updatable.contains { $0.id == s.id } }).isEmpty { model.confirmLive = true }
                    else { model.confirmUpdate = true }
                } label: { Label("Seçilileri güncelle (\(model.updatable.count))", systemImage: "arrow.down.circle.fill") }
                    .disabled(model.busy || model.updatable.isEmpty)
            }
            .padding(12)
            Divider()
            List {
                ForEach($model.rows) { $row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { model.selected.contains(row.id) },
                                                     set: { on in if on { model.selected.insert(row.id) } else { model.selected.remove(row.id) } }))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.server.name).fontWeight(.medium)
                                    if row.server.theme == .red { Text("CANLI").font(.caption2.bold()).foregroundStyle(.red) }
                                }
                                Text(statusText(row)).font(.callout).foregroundStyle(statusColor(row))
                            }
                            Spacer()
                            if row.busy { ProgressView().controlSize(.small) }
                            if row.check?.rebootRequired == true, !row.busy {
                                if row.rebootScheduled {
                                    Text("1 dk içinde yeniden başlıyor").font(.callout).foregroundStyle(.orange)
                                    Button("İptal et") { model.reboot(row.id, cancel: true) }
                                } else {
                                    Button { model.rebootTarget = row.id } label: { Label("Yeniden başlat…", systemImage: "restart") }
                                }
                            }
                        }
                        if let pk = row.check?.packages, !pk.isEmpty {
                            DisclosureGroup("Güncellenecek paketler (\(pk.count))") {
                                Text(pk.joined(separator: ", ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            .font(.callout)
                        }
                        if !row.log.isEmpty {
                            DisclosureGroup(isExpanded: Binding(get: { model.showLog.contains(row.id) },
                                                                set: { on in if on { model.showLog.insert(row.id) } else { model.showLog.remove(row.id) } })) {
                                ScrollView {
                                    Text(row.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 220)
                            } label: { Text("Çıktı").font(.callout) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            Text("Güvenli güncelleme: paket silinmez ve yeni paket kurulmaz (apt-get upgrade). Servisler kendiliğinden yeniden başlatılmaz. Yeniden başlatma 1 dakika sonra yapılır; bu sürede iptal edebilirsin. Şimdilik Ubuntu/Debian.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 720, minHeight: 440)
        .modifier(LiveServerConfirm(isPresented: $model.confirmLive, servers: model.liveSelected) { model.updateSelected() })
        .alert("Güncellemeler kurulsun mu?", isPresented: $model.confirmUpdate) {
            Button("Vazgeç", role: .cancel) {}
            Button("Güncelle") { model.updateSelected() }
        } message: {
            Text("\(model.updatable.map(\.server.name).joined(separator: ", ")) güncellenecek\(model.securityOnly ? " (sadece güvenlik)" : "").")
        }
        .alert("Sunucu yeniden başlatılsın mı?", isPresented: Binding(get: { model.rebootTarget != nil }, set: { if !$0 { model.rebootTarget = nil } })) {
            Button("Vazgeç", role: .cancel) { model.rebootTarget = nil }
            Button("1 dk sonra yeniden başlat", role: .destructive) { if let id = model.rebootTarget { model.reboot(id) }; model.rebootTarget = nil }
        } message: {
            Text("Sunucudaki siteler ve servisler 1-2 dakika erişilemez olur. 1 dakika içinde iptal edebilirsin.")
        }
    }

    private func statusText(_ r: UpdatesModel.Row) -> String {
        switch r.state {
        case .idle: return "Kontrol edilmedi"
        case .checking: return "Kontrol ediliyor…"
        case .updating: return "Güncelleniyor…"
        case .unsupported: return "Desteklenmiyor (apt yok; şimdilik Ubuntu/Debian)"
        case .failed(let m): return m
        case .updated:
            return (r.check?.rebootRequired ?? false) ? "Güncellendi · yeniden başlatma gerekiyor" : "Güncellendi"
        case .checked:
            guard let c = r.check else { return "" }
            var parts = [c.total == 0 ? "Güncel" : "\(c.total) güncelleme (\(c.security) güvenlik)"]
            if c.rebootRequired { parts.append("yeniden başlatma bekliyor") }
            if c.refreshFailed { parts.append("paket listesi tazelenemedi") }
            return parts.joined(separator: " · ")
        }
    }

    private func statusColor(_ r: UpdatesModel.Row) -> Color {
        switch r.state {
        case .failed: return .red
        case .updated: return .green
        case .checked: return (r.check?.security ?? 0) > 0 ? .orange : (r.check?.total ?? 0) > 0 ? .primary : .green
        default: return .secondary
        }
    }
}

func showUpdates(_ servers: [Server]) {
    WindowPresenter.shared.show("guncelleme", title: "Güncellemeler", size: NSSize(width: 820, height: 560), replace: true) {
        UpdatesView(model: UpdatesModel(servers: servers))
    }
}
