import AppKit
import SSHManagerKit

/// Sunucuda terminal açmadan komut çalıştırır (`ssh -T`) ve çıktıyı canlı verir.
///
/// - `interactive`: gerekirse native pencereler açılır (parola, parmak izi, sudo parolası).
/// - `silent`: arka plan işleri için; asla pencere açmaz, izin gerekiyorsa sessizce başarısız olur.
final class RemoteRun {
    enum Mode { case interactive, silent }

    struct Result {
        let exitCode: Int32
        let output: String
        let duration: TimeInterval
        let timedOut: Bool
        var ok: Bool { exitCode == 0 && !timedOut }
    }

    let server: Server
    private var process: Process?
    private var cancelled = false
    /// Çalışırken kendini canlı tutar: çağıran taraf referans tutmasa da ("RemoteRun(...).start")
    /// iş bitince tamamlanma çağrısı mutlaka gelir.
    private var keepAlive: RemoteRun?
    private(set) var output = ""

    init(server: Server) {
        self.server = server
    }

    /// Komutu çalıştırır. `asRoot` ise sudo gerektiği gibi halledilir (root / parolasız sudo / parolalı sudo).
    func start(command: String, asRoot: Bool, mode: Mode, timeout: TimeInterval = 600,
               onOutput: ((String) -> Void)? = nil, completion userCompletion: @escaping (Result) -> Void) {
        keepAlive = self
        let completion: (Result) -> Void = { [self] result in
            userCompletion(result)
            keepAlive = nil
        }
        let firstPassword = asRoot ? sudoPassword(mode: mode) : nil
        launch(command: command, asRoot: asRoot, password: firstPassword, mode: mode, timeout: timeout,
               onOutput: onOutput) { [weak self] result in
            guard let self = self else { return }
            // sudo parolası kabul edilmediyse (ön plandaysa) kullanıcıya bir kez sor ve tekrar dene.
            guard asRoot, mode == .interactive, !self.cancelled, !result.ok,
                  RemoteScripts.sudoPasswordRejected(result.output) else { return completion(result) }
            guard let typed = self.askSudoPassword(retry: firstPassword != nil) else { return completion(result) }
            onOutput?("\n— sudo parolası ile tekrar deneniyor —\n")
            self.launch(command: command, asRoot: true, password: typed, mode: mode, timeout: timeout,
                        onOutput: onOutput, completion: completion)
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    // MARK: - Süreç

    private func launch(command: String, asRoot: Bool, password: String?, mode: Mode, timeout: TimeInterval,
                        onOutput: ((String) -> Void)?, completion: @escaping (Result) -> Void) {
        output = ""
        let remote = asRoot ? RemoteScripts.asRoot(command) : command
        var args = SSHCommand.baseOptions(for: server) + ["-T", "-o", "ConnectTimeout=10"]
        if mode == .silent {
            // Parmak izi bilinmiyorsa sorma, parola bir kez denensin (sunucu tarafında engellenmeyelim).
            args += ["-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1"]
        }
        args += ["--", server.sshDestination, remote]

        var env = ProcessInfo.processInfo.environment.merging(
            SSHCommand.askpassEnvironment(helper: AppPaths.executable, serverID: server.id)) { _, new in new }
        if mode == .silent { env[SSHCommand.Env.silent] = "1" }
        // Giriş parolasını uygulama (kasadan, bir kez) verir; askpass Anahtar Zinciri'ne ayrıca gitmez.
        let pipe = storedPassword(account: server.keychainAccount, mode: mode).flatMap { PasswordPipe(password: $0) }
        if let pipe = pipe { env[SSHCommand.Env.passwordPipe] = pipe.path }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHCommand.sshPath)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = asRoot ? input : FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
            DispatchQueue.main.async {
                self?.output += text
                // BD_ satırları uygulamanın kendi işaretleri; kullanıcıya gösterilmez.
                let visible = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("BD_") }.joined(separator: "\n")
                if !visible.isEmpty { onOutput?(visible) }
            }
        }

        let started = Date()
        var timedOut = false
        let killer = DispatchWorkItem { [weak p] in
            timedOut = true
            p?.terminate()
        }
        p.terminationHandler = { [weak self] proc in
            killer.cancel()
            pipe?.close()
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let text = String(data: rest, encoding: .utf8), !text.isEmpty {
                    self.output += text
                    onOutput?(RemoteScripts.visibleOutput(text))
                }
                completion(Result(exitCode: proc.terminationStatus, output: self.output,
                                  duration: Date().timeIntervalSince(started), timedOut: timedOut))
            }
        }

        do {
            try p.run()
        } catch {
            pipe?.close()
            completion(Result(exitCode: 127, output: error.localizedDescription, duration: 0, timedOut: false))
            return
        }
        process = p
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        if asRoot {
            // Tek satır: kayıtlı parola ya da boş satır. Uzak sarmalayıcı gerekirse sudo'ya verir, gerekmezse atar.
            input.fileHandleForWriting.write(Data(((password ?? "") + "\n").utf8))
            try? input.fileHandleForWriting.close()
        }
    }

    // MARK: - sudo parolası

    private var sudoAccount: String { server.keychainAccount + "-sudo" }

    /// Önce sunucuya özel kayıtlı sudo parolası, yoksa giriş parolası (çoğu sunucuda aynıdır).
    private func sudoPassword(mode: Mode) -> String? {
        storedPassword(account: sudoAccount, mode: mode) ?? storedPassword(account: server.keychainAccount, mode: mode)
    }

    /// Kasadaki parola. Touch ID koruması açıksa önce kimlik doğrulanır; toplu işlerde bir onay bütün sunuculara yeter
    /// (`IdentityGate`). Arka planda (sessiz) Touch ID sorulamayacağı için korumalıyken parola kullanılmaz.
    private func storedPassword(account: String, mode: Mode) -> String? {
        guard KeychainHelper.hasPassword(account: account) else { return nil }
        if Settings.requireTouchID, !IdentityGate.isFresh {
            guard mode == .interactive, AskPass.authenticate(reason: "\(server.name) için kayıtlı parolayı kullanmak") else { return nil }
            IdentityGate.confirmed()
        }
        return KeychainHelper.readPassword(account: account, allowUI: mode == .interactive)
    }

    private func askSudoPassword(retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "\(server.name): sudo parolası kabul edilmedi" : "\(server.name): sudo parolası gerekli"
        alert.informativeText = "Bu işlem yönetici yetkisi istiyor. \(server.user) kullanıcısının sudo parolasını gir."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let save = NSButton(checkboxWithTitle: "Anahtar Zinciri'ne kaydet", target: nil, action: nil)
        save.state = .on
        let stack = NSStackView(views: [field, save])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Devam")
        alert.addButton(withTitle: "Vazgeç")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        if save.state == .on { KeychainHelper.savePassword(field.stringValue, account: sudoAccount) }
        return field.stringValue
    }
}

/// Sunucu parolalarının kasası (tek Anahtar Zinciri kaydı) için uygulama tarafı kısayollar.
enum PasswordVault {
    /// Bir sunucunun kasada olabilecek hesapları: giriş parolası ve (ayrı kaydedildiyse) sudo parolası.
    static func accounts(_ servers: [Server]) -> [String] {
        servers.flatMap { [$0.keychainAccount, $0.keychainAccount + "-sudo"] }
    }

    /// Kasayı açar, bu sunucuların eski tek kayıtlarını taşır. macOS en fazla bir kez (kasa için) izin sorar;
    /// eski sürümden kalan kayıtlar varsa onlar da son kez, sırayla sorulur.
    @discardableResult
    static func unlock(for servers: [Server]) -> Bool {
        KeychainHelper.unlock(migrating: accounts(servers))
    }

    /// Arka plan kontrolleri parolaları kullanabilir mi? (Uygulama güncellendikten sonra macOS'un bir kez izin vermesi gerekir.)
    static var isLocked: Bool {
        !KeychainHelper.isUnlocked(accounts: accounts(ServerStore.shared.servers))
    }
}

/// Touch ID onayının kısa bir süre geçerli sayılması: 100 sunuculuk toplu işte 100 kez parmak izi sorulmasın.
enum IdentityGate {
    private static var last: Date?
    static let validity: TimeInterval = 10 * 60

    static var isFresh: Bool { last.map { Date().timeIntervalSince($0) < validity } ?? false }
    static func confirmed() { last = Date() }
}

/// Aynı anda en fazla `limit` sunucuda çalışan basit iş kuyruğu (ana iş parçacığında yönetilir).
final class BatchQueue {
    private var pending: [() -> Void] = []
    private var running = 0
    private let limit: Int

    init(limit: Int = 4) { self.limit = limit }

    /// `job` bitince verilen `done` çağrılmalı.
    func add(_ job: @escaping (_ done: @escaping () -> Void) -> Void) {
        pending.append { [weak self] in
            job { DispatchQueue.main.async { self?.running -= 1; self?.next() } }
        }
        next()
    }

    private func next() {
        while running < limit, !pending.isEmpty {
            running += 1
            pending.removeFirst()()
        }
    }
}
