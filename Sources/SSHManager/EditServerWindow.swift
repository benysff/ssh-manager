import AppKit

/// Sunucu ekleme/düzenleme penceresi. Programatik AppKit formu.
final class EditServerWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow!
    private let onSave: (Server, String?) -> Void

    private var editing: Server?

    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let groupField = NSTextField()
    private let postField = NSTextField()
    private let passwordField = NSSecureTextField()

    /// onSave: kaydedilen sunucu ve (girildiyse) parola. Parola nil ise değiştirme.
    init(server: Server?, onSave: @escaping (Server, String?) -> Void) {
        self.editing = server
        self.onSave = onSave
        super.init()
        buildWindow()
        populate(from: server)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    // MARK: - UI kurulumu

    private func buildWindow() {
        let width: CGFloat = 420
        let height: CGFloat = 360
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = editing == nil ? "Yeni Sunucu" : "Sunucuyu Düzenle"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let labels = ["Ad:", "Host:", "Port:", "Kullanıcı:", "Grup:", "Bağlantı sonrası komut:", "Parola:"]
        let fields: [NSTextField] = [nameField, hostField, portField, userField, groupField, postField, passwordField]
        let placeholders = ["Örn. Production Web", "192.168.1.10 veya ornek.com", "22", "root", "Production (opsiyonel)", "cd /var/www && tmux a (opsiyonel)", "Boş bırakırsan elle gireceksin"]

        let rowHeight: CGFloat = 32
        let topPadding: CGFloat = 16
        let labelWidth: CGFloat = 170
        let fieldX: CGFloat = labelWidth + 24

        for (i, field) in fields.enumerated() {
            let y = height - topPadding - rowHeight * CGFloat(i + 1) - 30

            let label = NSTextField(labelWithString: labels[i])
            label.alignment = .right
            label.frame = NSRect(x: 12, y: y, width: labelWidth, height: 22)
            content.addSubview(label)

            field.frame = NSRect(x: fieldX, y: y, width: width - fieldX - 16, height: 24)
            field.placeholderString = placeholders[i]
            field.isBordered = true
            field.bezelStyle = .roundedBezel
            content.addSubview(field)
        }

        // Butonlar
        let saveButton = NSButton(title: "Kaydet", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: width - 110, y: 16, width: 94, height: 30)
        content.addSubview(saveButton)

        let cancelButton = NSButton(title: "İptal", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.frame = NSRect(x: width - 210, y: 16, width: 94, height: 30)
        content.addSubview(cancelButton)

        window.contentView = content
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
        postField.stringValue = s.postCommand
        // Parola alanı boş kalır; doldurulursa güncellenir, boşsa eskisi korunur.
        if KeychainHelper.hasPassword(account: s.keychainAccount) {
            passwordField.placeholderString = "•••••• (kayıtlı — değiştirmek için yaz)"
        }
    }

    // MARK: - Aksiyonlar

    @objc private func saveTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, !host.isEmpty, !user.isEmpty else {
            showAlert("Ad, Host ve Kullanıcı alanları zorunludur.")
            return
        }
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22

        var server = editing ?? Server(name: name, host: host, port: port, user: user)
        server.name = name
        server.host = host
        server.port = port
        server.user = user
        server.group = groupField.stringValue.trimmingCharacters(in: .whitespaces)
        server.postCommand = postField.stringValue.trimmingCharacters(in: .whitespaces)

        let pwd = passwordField.stringValue
        onSave(server, pwd.isEmpty ? nil : pwd)

        window.close()
    }

    @objc private func cancelTapped() {
        window.close()
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Eksik Bilgi"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
