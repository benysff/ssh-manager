import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var editWindows: [EditServerWindow] = [] // referansları canlı tut

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock'ta görünme, sadece menü çubuğunda yaşa.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "SSH Manager")
            button.image?.isTemplate = true
        }

        rebuildMenu()
    }

    // MARK: - Menü kurulumu

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let store = ServerStore.shared
        let groups = store.grouped()

        if groups.isEmpty {
            let empty = NSMenuItem(title: "Henüz sunucu yok", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (group, servers) in groups {
                // Birden fazla grup varsa başlık göster.
                if groups.count > 1 {
                    let header = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                for server in servers {
                    menu.addItem(makeServerItem(server, indented: groups.count > 1))
                }
                if groups.count > 1 {
                    menu.addItem(.separator())
                }
            }
        }

        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Yeni Sunucu Ekle…", action: #selector(addServer), keyEquivalent: "n")
        addItem.target = self
        menu.addItem(addItem)

        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func makeServerItem(_ server: Server, indented: Bool) -> NSMenuItem {
        let title = indented ? "  \(server.name)" : server.name
        let item = NSMenuItem(title: title, action: #selector(connectServer(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = server
        item.toolTip = "\(server.sshDestination):\(server.port)"

        // Sağda parola durumunu küçük bir ikonla göster.
        let symbol = KeychainHelper.hasPassword(account: server.keychainAccount) ? "key.fill" : "key"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.image?.isTemplate = true

        // Alt menü: Düzenle / Sil
        let submenu = NSMenu()

        let connectSub = NSMenuItem(title: "Bağlan", action: #selector(connectServer(_:)), keyEquivalent: "")
        connectSub.target = self
        connectSub.representedObject = server
        submenu.addItem(connectSub)

        submenu.addItem(.separator())

        let edit = NSMenuItem(title: "Düzenle…", action: #selector(editServer(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = server
        submenu.addItem(edit)

        let delete = NSMenuItem(title: "Sil", action: #selector(deleteServer(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = server
        submenu.addItem(delete)

        item.submenu = submenu
        return item
    }

    // MARK: - Aksiyonlar

    @objc private func connectServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? Server else { return }
        do {
            try ITermLauncher.connect(to: server)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func addServer() {
        let editor = EditServerWindow(server: nil) { [weak self] server, password in
            ServerStore.shared.add(server)
            if let password = password {
                KeychainHelper.savePassword(password, account: server.keychainAccount)
            }
            self?.rebuildMenu()
        }
        editWindows.append(editor)
        editor.show()
    }

    @objc private func editServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? Server else { return }
        let editor = EditServerWindow(server: server) { [weak self] updated, password in
            ServerStore.shared.update(updated)
            if let password = password {
                KeychainHelper.savePassword(password, account: updated.keychainAccount)
            }
            self?.rebuildMenu()
        }
        editWindows.append(editor)
        editor.show()
    }

    @objc private func deleteServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? Server else { return }
        let alert = NSAlert()
        alert.messageText = "Sunucuyu sil?"
        alert.informativeText = "\(server.name) (\(server.sshDestination)) silinecek. Kayıtlı parolası da silinir."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "İptal")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ServerStore.shared.remove(server)
            rebuildMenu()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
