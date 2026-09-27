import AppKit
import LocalAuthentication
import SSHManagerKit

/// ssh'ın SSH_ASKPASS ile sorduğu soruları yanıtlar. Cevap stdout'a yazılır; ssh onu okur.
///
///  - Parola: ilk denemede Keychain'deki parola (istenirse Touch ID sonrası) verilir.
///    Parola kabul edilmezse native bir pencereyle yenisi sorulur ve istenirse kaydedilir.
///  - İlk bağlantıdaki host key sorusu: parmak izini gösteren native onay penceresi.
///  - Diğerleri (doğrulama kodu, anahtar parolası): native giriş penceresi.
enum AskPass {

    static func run(arguments: [String]) -> Int32 {
        let prompt = arguments.first ?? ""
        let env = ProcessInfo.processInfo.environment
        let server = env[SSHCommand.Env.serverID]
            .flatMap(UUID.init(uuidString:))
            .flatMap { ServerStore.shared.server(id: $0) }

        let kind = AskPassPrompt.classify(prompt, promptEnv: env["SSH_ASKPASS_PROMPT"])
        if env[SSHCommand.Env.silent] == "1" {
            return silent(kind: kind, server: server)
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        switch kind {
        case .hostKey: return hostKey(prompt: prompt, server: server)
        case .confirm: return confirm(prompt: prompt)
        case .password: return password(prompt: prompt, server: server)
        case .passphrase: return ask(title: "Anahtar parolası", message: prompt, secure: true)
        case .other: return ask(title: server.map { "\($0.name) soruyor" } ?? "SSH soruyor", message: prompt, secure: true)
        }
    }

    // MARK: - Sessiz mod (arka plan kontrolleri)

    /// Hiçbir pencere açmaz: sadece ilk denemede, izin sormadan okunabilen kayıtlı parolayı verir.
    /// Touch ID koruması açıksa parola hiç verilmez (arka planda parmak izi sorulamaz).
    private static func silent(kind: AskPassPrompt, server: Server?) -> Int32 {
        guard kind == .password, let s = server, !Settings.requireTouchID else { return 1 }
        let attempt = AttemptCounter.next(key: "\(getppid())-\(s.id.uuidString)")
        guard attempt == 1, let pw = KeychainHelper.readPassword(account: s.keychainAccount, allowUI: false) else { return 1 }
        reply(pw)
        return 0
    }

    // MARK: - Parola

    private static func password(prompt: String, server: Server?) -> Int32 {
        // Aynı ssh süreci ikinci kez soruyorsa kayıtlı parola yanlış demektir.
        let attempt = AttemptCounter.next(key: "\(getppid())-\(server?.id.uuidString ?? "yok")")

        if attempt == 1, let s = server, KeychainHelper.hasPassword(account: s.keychainAccount) {
            if Settings.requireTouchID {
                guard authenticate(reason: "\(s.name) sunucusuna bağlanmak") else { return 1 }
            }
            if let pw = KeychainHelper.readPassword(account: s.keychainAccount) {
                reply(pw)
                return 0
            }
        }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        var save: NSButton?
        if server != nil {
            let box = NSButton(checkboxWithTitle: "Anahtar Zinciri'ne kaydet (bir daha sorma)", target: nil, action: nil)
            box.state = .on
            save = box
        }
        let title: String
        let message: String
        if let s = server {
            title = attempt > 1 ? "Parola kabul edilmedi" : "\(s.name) için parola"
            message = attempt > 1
                ? "\(s.sshDestination) kayıtlı parolayı kabul etmedi. Doğru parolayı gir."
                : "\(s.sshDestination) parolasını gir."
        } else {
            title = "Parola gerekli"
            message = prompt
        }
        guard showDialog(title: title, message: message, views: [field] + (save.map { [$0] } ?? []),
                         ok: "Bağlan", focus: field) else { return 1 }
        let value = field.stringValue
        if let s = server, save?.state == .on, !value.isEmpty {
            KeychainHelper.savePassword(value, account: s.keychainAccount)
        }
        reply(value)
        return 0
    }

    // MARK: - Host key ve onaylar

    private static func hostKey(prompt: String, server: Server?) -> Int32 {
        let fingerprint = prompt.range(of: #"SHA256:[A-Za-z0-9+/=]+"#, options: .regularExpression)
            .map { String(prompt[$0]) } ?? ""
        let who = server.map { "\($0.name) (\($0.host))" } ?? "Bu sunucu"
        let message = """
        \(who) ile ilk kez bağlanıyorsun. Bilgisayarın sunucunun kimliğini henüz tanımıyor.

        Parmak izi:
        \(fingerprint.isEmpty ? prompt : fingerprint)

        Bu sunucuyu sen kurduysan ya da tanıyorsan güvenle devam edebilirsin. Bir daha sorulmaz.
        """
        let alert = NSAlert()
        alert.messageText = "Yeni sunucu: güveniyor musun?"
        alert.informativeText = message
        alert.addButton(withTitle: "Güven ve bağlan")
        alert.addButton(withTitle: "Vazgeç")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
        reply("yes")
        return 0
    }

    private static func confirm(prompt: String) -> Int32 {
        let alert = NSAlert()
        alert.messageText = "SSH onay istiyor"
        alert.informativeText = prompt
        alert.addButton(withTitle: "İzin ver")
        alert.addButton(withTitle: "Reddet")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? 0 : 1
    }

    private static func ask(title: String, message: String, secure: Bool) -> Int32 {
        let field: NSTextField = secure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        guard showDialog(title: title, message: message, views: [field], ok: "Tamam", focus: field) else { return 1 }
        reply(field.stringValue)
        return 0
    }

    // MARK: - Yardımcılar

    private static func showDialog(title: String, message: String, views: [NSView], ok: String, focus: NSView) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Vazgeç")
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(views.count) * 30)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = focus
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Touch ID (ya da Mac parolası) ile kimlik doğrular.
    static func authenticate(reason: String) -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            ok = success
            done.signal()
        }
        done.wait()
        return ok
    }

    /// Cevabı ssh'a yazar. ssh bu arada vazgeçip bağlantıyı kapattıysa (kırık boru) sessizce çıkar;
    /// FileHandle.write bu durumda yakalanamayan bir istisna fırlatıp süreci çökertiyordu.
    private static func reply(_ value: String) {
        signal(SIGPIPE, SIG_IGN)
        let bytes = Array((value + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            offset += n
        }
    }
}
