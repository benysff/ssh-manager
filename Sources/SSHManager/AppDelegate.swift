import AppKit
import ServiceManagement
import SSHManagerKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var editWindows: [EditServerWindow] = [] // referansları canlı tut
    private let quickConnect = QuickConnectPanel()
    private var hotKey: HotKey?
    private var keySetupRunning: Set<UUID> = []

    private var store: ServerStore { ServerStore.shared }
    private let tunnels = TunnelManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock'ta görünme, sadece menü çubuğunda yaşa.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        quickConnect.onConnect = { [weak self] in self?.connect($0) }
        quickConnect.onFiles = { [weak self] in self?.openFiles($0) }
        hotKey = HotKey { [weak self] in self?.quickConnect.show() }

        tunnels.onChange = { [weak self] in self?.updateIcon() }
        tunnels.onFailure = { [weak self] server, tunnel, reason in
            self?.presentError("\(server.name) tüneli kapandı (\(tunnel.title)).\n\n\(reason)")
        }

        if let error = store.loadError { presentError(error) }
    }

    /// Raycast, Alfred, Kestirmeler gibi araçlardan:
    ///   sshmanager://connect/<ad>   sshmanager://files/<ad>   sshmanager://quick
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "sshmanager" {
            let action = url.host ?? ""
            let name = url.pathComponents.dropFirst().first?.removingPercentEncoding ?? ""
            store.load()
            switch action {
            case "quick":
                quickConnect.show()
            case "connect", "files":
                guard let server = store.find(name) else {
                    presentError("Sunucu bulunamadı: \(name)")
                    continue
                }
                action == "connect" ? connect(server) : openFiles(server)
            default:
                break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnels.stopAll()
    }

    /// Menü her açıldığında güncel listeyle yeniden kurulur (sshm ile yapılan değişiklikler de görünür).
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.load()
        rebuild(menu)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let active = tunnels.activeCount > 0
        button.image = NSImage(systemSymbolName: active ? "terminal.fill" : "terminal",
                               accessibilityDescription: "SSHManager")
        button.image?.isTemplate = true
        button.toolTip = active ? "SSHManager — \(tunnels.activeCount) tünel açık" : "SSHManager"
    }

    // MARK: - Menü

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error = store.loadError {
            menu.addItem(disabled("Sunucu listesi okunamadı"))
            menu.addItem(disabled(error))
            menu.addItem(.separator())
        }

        menu.addItem(item("Hızlı bağlan…", #selector(showQuickConnect), key: "s", modifiers: [.control, .option]))
        menu.addItem(.separator())

        let groups = store.grouped()
        if groups.isEmpty {
            menu.addItem(disabled("Henüz sunucu yok"))
        }
        for (group, servers) in groups {
            if groups.count > 1 {
                menu.addItem(header(group))
            }
            for server in servers {
                menu.addItem(serverItem(server))
            }
        }

        menu.addItem(.separator())
        let add = item("Yeni sunucu ekle…", #selector(addServer), key: "n")
        add.isEnabled = store.loadError == nil
        menu.addItem(add)
        let importItem = item("~/.ssh/config'ten içe aktar…", #selector(importSSHConfig))
        importItem.isEnabled = store.loadError == nil
        menu.addItem(importItem)
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        menu.addItem(item("Çıkış", #selector(quit), key: "q"))
    }

    private func serverItem(_ server: Server) -> NSMenuItem {
        let item = NSMenuItem(title: server.name, action: #selector(connectItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = server.id
        item.toolTip = "\(server.sshDestination):\(server.port) · terminalde: sshm \(store.alias(of: server))"

        let hasKey = !server.identityFile.isEmpty
        let hasPassword = KeychainHelper.hasPassword(account: server.keychainAccount)
        let activeTunnels = server.tunnels.filter { tunnels.isActive(server, $0) }.count
        let symbol = activeTunnels > 0 ? "point.3.connected.trianglepath.dotted"
            : hasKey ? "key.horizontal.fill" : hasPassword ? "key.fill" : "key"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.image?.isTemplate = true

        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(serverAction("Bağlan", #selector(connectItem(_:)), server))
        let files = serverAction("Dosyalar (Midnight Commander)", #selector(filesItem(_:)), server)
        files.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        sub.addItem(files)

        if !server.tunnels.isEmpty {
            sub.addItem(.separator())
            sub.addItem(header("Tüneller"))
            for (index, tunnel) in server.tunnels.enumerated() {
                let t = NSMenuItem(title: tunnel.title, action: #selector(toggleTunnel(_:)), keyEquivalent: "")
                t.target = self
                t.representedObject = [server.id.uuidString, String(index)]
                t.state = tunnels.isActive(server, tunnel) ? .on : .off
                sub.addItem(t)
            }
        }

        sub.addItem(.separator())
        if !hasKey {
            let running = keySetupRunning.contains(server.id)
            let setup = serverAction(running ? "Anahtar yükleniyor…" : "Parolasız girişe geç (SSH anahtarı)…",
                                     #selector(setupKey(_:)), server)
            setup.isEnabled = !running
            sub.addItem(setup)
        }
        sub.addItem(serverAction("ssh komutunu kopyala", #selector(copyCommand(_:)), server))
        sub.addItem(.separator())
        sub.addItem(serverAction("Düzenle…", #selector(editServer(_:)), server))
        sub.addItem(serverAction("Sil", #selector(deleteServer(_:)), server))
        item.submenu = sub
        return item
    }

    private func settingsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Ayarlar", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(header("Bağlantılar şurada açılsın"))
        for choice in TerminalChoice.allCases {
            let i = item(choice.title, #selector(chooseTerminal(_:)))
            i.representedObject = choice.rawValue
            i.state = Settings.terminal == choice ? .on : .off
            sub.addItem(i)
        }
        let tabs = item("Terminal'de yeni sekmede aç", #selector(toggleTabs))
        tabs.state = Settings.terminalTabs ? .on : .off
        tabs.isEnabled = Settings.terminal == .terminal
        tabs.toolTip = "Erişilebilirlik izni gerekir. Kapalıysa her bağlantı yeni pencerede açılır."
        sub.addItem(tabs)

        sub.addItem(.separator())
        let touch = item("Kayıtlı parolayı kullanmadan önce Touch ID iste", #selector(toggleTouchID))
        touch.state = Settings.requireTouchID ? .on : .off
        sub.addItem(touch)

        let login = item("Oturum açılınca başlat", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sub.addItem(login)

        sub.addItem(.separator())
        let cliTitle = CLIInstaller.installedPath.map { _ in "Terminal komutu kurulu: sshm" } ?? "Terminal komutunu kur (sshm)…"
        let cli = item(cliTitle, #selector(installCLI))
        cli.isEnabled = CLIInstaller.installedPath == nil
        sub.addItem(cli)

        root.submenu = sub
        return root
    }

    // MARK: - Menü yardımcıları

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if !key.isEmpty { i.keyEquivalentModifierMask = modifiers }
        return i
    }

    private func serverAction(_ title: String, _ action: Selector, _ server: Server) -> NSMenuItem {
        let i = item(title, action)
        i.representedObject = server.id
        return i
    }

    /// Bölüm başlığı (macOS 13 uyumlu: NSMenuItem.sectionHeader 14+ istiyor).
    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func server(from sender: NSMenuItem) -> Server? {
        (sender.representedObject as? UUID).flatMap { store.server(id: $0) }
    }

    // MARK: - Bağlantı

    @objc private func showQuickConnect() { quickConnect.show() }

    @objc private func connectItem(_ sender: NSMenuItem) {
        if let s = server(from: sender) { connect(s) }
    }

    @objc private func filesItem(_ sender: NSMenuItem) {
        if let s = server(from: sender) { openFiles(s) }
    }

    private func connect(_ server: Server) {
        ensureTabPermissionOnce()
        do {
            try TerminalLauncher.runSelf(["connect", server.id.uuidString], title: server.name, theme: server.theme)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func openFiles(_ server: Server) {
        guard CLI.findMC() != nil else {
            let alert = NSAlert()
            alert.messageText = "Midnight Commander kurulu değil"
            alert.informativeText = "Dosyaları iki panelde (solda Mac'in, sağda sunucu) yönetmek için Midnight Commander gerekiyor.\n\nTerminalde şunu çalıştır:\n    brew install mc"
            alert.addButton(withTitle: "Komutu kopyala")
            alert.addButton(withTitle: "Kapat")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { copyToClipboard("brew install mc") }
            return
        }
        ensureTabPermissionOnce()
        do {
            try TerminalLauncher.runSelf(["files", server.id.uuidString], title: "Dosyalar — \(server.name)", theme: server.theme)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    /// Terminal.app'te sekme açmak Erişilebilirlik izni ister; ilk seferde bir kez sorar.
    private func ensureTabPermissionOnce() {
        guard Settings.terminal == .terminal, Settings.terminalTabs,
              !TerminalLauncher.accessibilityGranted(prompt: false) else { return }
        let key = "tabPermissionAsked"
        let defaults = UserDefaults(suiteName: "com.yusuf.sshmanager.ayarlar")!
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        _ = TerminalLauncher.accessibilityGranted(prompt: true)
    }

    @objc private func toggleTunnel(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2,
              let id = UUID(uuidString: parts[0]), let index = Int(parts[1]),
              let server = store.server(id: id), index < server.tunnels.count else { return }
        let tunnel = server.tunnels[index]
        if tunnels.isActive(server, tunnel) {
            tunnels.stop(server, tunnel)
        } else {
            do {
                try tunnels.start(server, tunnel)
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    @objc private func copyCommand(_ sender: NSMenuItem) {
        guard let s = server(from: sender) else { return }
        copyToClipboard(SSHCommand.displayCommand(for: s))
    }

    @objc private func setupKey(_ sender: NSMenuItem) {
        guard let s = server(from: sender) else { return }
        let plan = KeySetup.plan(for: s)
        let alert = NSAlert()
        alert.messageText = "\(s.name): parolasız girişe geç"
        alert.informativeText = """
        \(plan.willGenerate ? "Bilgisayarında yeni bir SSH anahtarı oluşturulacak (\((plan.privateKey as NSString).abbreviatingWithTildeInPath))." : "Mevcut anahtarın kullanılacak: \((plan.publicKey as NSString).abbreviatingWithTildeInPath)")

        Anahtarın açık kısmı sunucudaki ~/.ssh/authorized_keys dosyasına eklenecek. Bunun için parolan bir kez kullanılır.

        Sonrasında bu sunucuya parola sormadan bağlanırsın; dosya yöneticisi (mc), scp ve git gibi araçlar da parolasız çalışır.
        """
        alert.addButton(withTitle: "Devam et")
        alert.addButton(withTitle: "Vazgeç")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        keySetupRunning.insert(s.id)
        KeySetup.run(for: s) { [weak self] result in
            guard let self = self else { return }
            self.keySetupRunning.remove(s.id)
            switch result {
            case .success(let updated):
                do {
                    try self.store.update(updated)
                    self.presentInfo("Hazır", "\(s.name) sunucusuna artık parola sormadan bağlanıyorsun.")
                } catch {
                    self.presentError(error.localizedDescription)
                }
            case .failure(let error):
                self.presentError(error.localizedDescription)
            }
        }
    }

    // MARK: - Sunucu ekle / düzenle / sil

    private var existingGroups: [String] {
        Array(Set(store.servers.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    @objc private func addServer() {
        openEditor(nil)
    }

    @objc private func editServer(_ sender: NSMenuItem) {
        if let s = server(from: sender) { openEditor(s) }
    }

    private func openEditor(_ server: Server?) {
        let editor = EditServerWindow(server: server, groups: existingGroups) { [weak self] saved, password in
            guard let self = self else { return }
            do {
                if server == nil { try self.store.add(saved) } else { try self.store.update(saved) }
                if let password = password {
                    KeychainHelper.savePassword(password, account: saved.keychainAccount)
                }
                self.tunnels.prune(keeping: self.store.servers)
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
        editWindows.removeAll { !$0.isVisible }
        editWindows.append(editor)
        editor.show()
    }

    @objc private func deleteServer(_ sender: NSMenuItem) {
        guard let server = server(from: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Sunucuyu sil?"
        alert.informativeText = "\(server.name) (\(server.sshDestination)) silinecek. Kayıtlı parolası da silinir."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "İptal")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.remove(server)
            tunnels.prune(keeping: store.servers)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func importSSHConfig() {
        let path = Paths.expandTilde("~/.ssh/config")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return presentInfo("İçe aktarılacak bir şey yok", "~/.ssh/config dosyası bulunamadı.")
        }
        let found = SSHConfigImporter.newServers(from: SSHConfigImporter.parse(text),
                                                 existing: store.servers, defaultUser: NSUserName())
        guard !found.isEmpty else {
            return presentInfo("Yeni sunucu yok", "~/.ssh/config içindeki sunucuların hepsi zaten listede.")
        }
        let alert = NSAlert()
        alert.messageText = "\(found.count) sunucu bulundu"
        alert.informativeText = found.map { "• \($0.name)  (\($0.sshDestination))" }.joined(separator: "\n")
            + "\n\n\"İçe aktarılan\" grubuna eklenecek. Parolaları ilk bağlantıda sorulur."
        alert.addButton(withTitle: "Ekle")
        alert.addButton(withTitle: "Vazgeç")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for s in found { try store.add(s) }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Ayarlar

    @objc private func chooseTerminal(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let choice = TerminalChoice(rawValue: raw) {
            Settings.terminal = choice
        }
    }

    @objc private func toggleTabs() {
        Settings.terminalTabs.toggle()
        if Settings.terminalTabs { _ = TerminalLauncher.accessibilityGranted(prompt: true) }
    }

    @objc private func toggleTouchID() {
        // Kapatmak da kimlik doğrulama istesin; yoksa koruma bir tıkla devre dışı kalır.
        if Settings.requireTouchID, !AskPass.authenticate(reason: "Touch ID korumasını kapatmak") { return }
        Settings.requireTouchID.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentError("Oturum açılışı ayarlanamadı: \(error.localizedDescription)")
        }
    }

    @objc private func installCLI() {
        do {
            let result = try CLIInstaller.install()
            var text = "Artık terminalde şunları yazabilirsin:\n\n  sshm              → sunucu listesi\n  sshm <ad>         → bağlan\n  sshm <ad> 'df -h' → komut çalıştır\n  sshm files <ad>   → dosyalar (mc)\n\nKurulum yeri: \(result.path)"
            if result.completionAdded { text += "\nSekme tamamlama ~/.zshrc'ye eklendi." }
            if result.completionAdded || !result.inPath { text += "\n\nYeni açacağın terminal pencerelerinde geçerli olur." }
            presentInfo("sshm kuruldu", text)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Uyarılar

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func presentInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Hata"
        alert.informativeText = message
        alert.alertStyle = .critical
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
