import AppKit
import SSHManagerKit

/// Sunucu ekleme/düzenleme penceresi.
final class EditServerWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow!
    private let onSave: (Server, String?) -> Void
    private let editing: Server?

    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let groupField = NSComboBox()
    private let passwordField = NSSecureTextField()
    private let keyField = NSTextField()
    private let postField = NSTextField()
    private let tunnelsField = NSTextField()
    private let themePopup = NSPopUpButton()
    private let tmuxCheck = NSButton(checkboxWithTitle: "Bağlantı koparsa kaldığın yerden devam et (tmux)", target: nil, action: nil)

    /// onSave: kaydedilen sunucu ve (girildiyse) parola. Parola nil ise değiştirme.
    init(server: Server?, groups: [String], onSave: @escaping (Server, String?) -> Void) {
        self.editing = server
        self.onSave = onSave
        super.init()
        groupField.addItems(withObjectValues: groups)
        buildWindow()
        populate(from: server)
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nameField)
    }

    // MARK: - Arayüz

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = editing == nil ? "Yeni Sunucu" : "Sunucuyu Düzenle"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let placeholders: [(NSTextField, String)] = [
            (nameField, "Ör. Canlı Web"),
            (hostField, "192.168.1.10 veya ornek.com"),
            (portField, "22"),
            (userField, "root"),
            (groupField, "Ör. Müşteri A (isteğe bağlı)"),
            (passwordField, "Boş bırakırsan ilk bağlantıda sorulur"),
            (keyField, "~/.ssh/id_ed25519 (isteğe bağlı)"),
            (postField, "Ör. cd /var/www (isteğe bağlı)"),
            (tunnelsField, "Ör. 5433:5432, 8080:localhost:80"),
        ]
        for (field, text) in placeholders {
            field.placeholderString = text
        }
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        themePopup.addItems(withTitles: ServerTheme.allCases.map(\.title))

        let chooseKey = NSButton(title: "Seç…", target: self, action: #selector(chooseKeyFile))
        chooseKey.bezelStyle = .rounded
        let keyRow = NSStackView(views: [keyField, chooseKey])
        keyRow.spacing = 6

        let hostRow = NSStackView(views: [hostField, label("Port:"), portField])
        hostRow.spacing = 6

        func help(_ text: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: text)
            t.font = .systemFont(ofSize: 11)
            t.textColor = .secondaryLabelColor
            return t
        }

        let grid = NSGridView(views: [
            [label("Ad:"), nameField],
            [label("Host:"), hostRow],
            [label("Kullanıcı:"), userField],
            [label("Grup:"), groupField],
            [label("Parola:"), passwordField],
            [label("SSH anahtarı:"), keyRow],
            [label("Bağlanınca çalıştır:"), postField],
            [label("Tüneller:"), tunnelsField],
            [NSGridCell.emptyContentView, help("Sunucudaki bir kapıyı kendi bilgisayarına bağlar. 5433:5432 → sunucudaki veritabanı localhost:5433'te açılır. Menüden açıp kapatırsın.")],
            [label("Terminal rengi:"), themePopup],
            [NSGridCell.emptyContentView, tmuxCheck],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 10
        grid.rowSpacing = 10
        grid.column(at: 1).width = 360

        let save = NSButton(title: "Kaydet", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "İptal", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 8

        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        window.contentView = root
        window.setContentSize(root.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func populate(from server: Server?) {
        guard let s = server else {
            portField.stringValue = "22"
            return
        }
        nameField.stringValue = s.name
        hostField.stringValue = s.host
        portField.stringValue = String(s.port)
        userField.stringValue = s.user
        groupField.stringValue = s.group
        keyField.stringValue = s.identityFile
        postField.stringValue = s.postCommand
        tunnelsField.stringValue = s.tunnels.map(\.spec).joined(separator: ", ")
        themePopup.selectItem(at: ServerTheme.allCases.firstIndex(of: s.theme) ?? 0)
        tmuxCheck.state = s.useTmux ? .on : .off
        // Parola alanı boş kalır; doldurulursa güncellenir, boşsa eskisi korunur.
        if KeychainHelper.hasPassword(account: s.keychainAccount) {
            passwordField.placeholderString = "•••••• (kayıtlı — değiştirmek için yaz)"
        }
    }

    // MARK: - Aksiyonlar

    @objc private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: Paths.expandTilde("~/.ssh"))
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.message = "Özel anahtar dosyasını seç (.pub olmayanı)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.keyField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func saveTapped() {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let port = Int(trim(portField.stringValue).isEmpty ? "22" : trim(portField.stringValue)) else {
            return showAlert("Port bir sayı olmalı.")
        }

        var server = editing ?? Server(name: "", host: "", user: "")
        server.name = trim(nameField.stringValue)
        server.host = trim(hostField.stringValue)
        server.port = port
        server.user = trim(userField.stringValue)
        server.group = trim(groupField.stringValue)
        server.identityFile = trim(keyField.stringValue)
        server.postCommand = trim(postField.stringValue)
        server.theme = ServerTheme.allCases[max(0, themePopup.indexOfSelectedItem)]
        server.useTmux = tmuxCheck.state == .on

        if let error = server.validationError { return showAlert(error) }
        do {
            server.tunnels = try Tunnel.parseList(tunnelsField.stringValue)
        } catch {
            return showAlert(error.localizedDescription)
        }
        if !server.identityFile.isEmpty, !FileManager.default.fileExists(atPath: Paths.expandTilde(server.identityFile)) {
            return showAlert("Anahtar dosyası bulunamadı: \(server.identityFile)")
        }

        let pwd = passwordField.stringValue
        onSave(server, pwd.isEmpty ? nil : pwd)
        window.close()
    }

    @objc private func cancelTapped() {
        window.close()
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Kontrol et"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}
