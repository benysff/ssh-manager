import AppKit
import ApplicationServices
import SSHManagerKit

/// Seçilen terminali (Terminal.app ya da iTerm2) AppleScript ile açıp içinde komut çalıştırır.
///
/// Terminale parola ASLA yazılmaz: gönderilen komut sadece `SSHManager connect <id>` gibi kısa bir
/// çağrıdır. Parolayı ssh, SSH_ASKPASS üzerinden doğrudan bu uygulamadan ister.
enum TerminalLauncher {

    enum LaunchError: Error, LocalizedError {
        case scriptFailed(String)
        var errorDescription: String? {
            switch self {
            case .scriptFailed(let msg): return "Terminal açılamadı: \(msg)"
            }
        }
    }

    /// Bu uygulamanın bir alt komutunu terminalde çalıştırır (ör. ["connect", id]).
    static func runSelf(_ subcommand: [String], title: String, theme: ServerTheme) throws {
        try execute(script(for: subcommand, title: title, theme: theme))
    }

    static func script(for subcommand: [String], title: String, theme: ServerTheme) -> String {
        var parts = [AppPaths.executable] + subcommand
        // Özel veri klasörüyle çalışılıyorsa (test/geliştirme) terminaldeki sürece de aktar.
        if let dir = ProcessInfo.processInfo.environment["SSHMANAGER_DATA_DIR"], !dir.isEmpty {
            parts = ["env", "SSHMANAGER_DATA_DIR=\(dir)"] + parts
        }
        let command = "exec " + parts.map(SSHCommand.shellQuote).joined(separator: " ")
        switch Settings.terminal {
        case .terminal: return terminalScript(command: command, title: title, theme: theme)
        case .iterm: return itermScript(command: command, title: title, theme: theme)
        }
    }

    /// Sekme açmak için gereken Erişilebilirlik izni var mı? `prompt` true ise macOS izin penceresini açar.
    static func accessibilityGranted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Terminal.app

    private static let terminalProfiles: [ServerTheme: String] = [.red: "Red Sands", .green: "Grass", .blue: "Ocean"]

    private static func terminalScript(command: String, title: String, theme: ServerTheme) -> String {
        let running = isRunning("com.apple.Terminal")
        // Terminal ⌘T için Erişilebilirlik izni ister; yoksa yeni pencere açılır.
        let useTab = running && Settings.terminalTabs && accessibilityGranted(prompt: false)
        let cmd = escape(command)

        var s = "tell application \"Terminal\" to activate\n"
        if !running {
            // Yeni açılan Terminal kendi boş penceresini açar; ikinci pencere açmak yerine onu kullan.
            s += """
            repeat 30 times
                tell application "Terminal" to if (count of windows) > 0 then exit repeat
                delay 0.1
            end repeat
            tell application "Terminal"
                if (count of windows) > 0 then
                    set t to do script "\(cmd)" in front window
                else
                    set t to do script "\(cmd)"
                end if
            end tell

            """
        } else if useTab {
            s += """
            tell application "Terminal"
                set hadWindows to (count of windows) > 0
            end tell
            if hadWindows then
                tell application "System Events" to tell process "Terminal" to keystroke "t" using command down
                delay 0.3
                tell application "Terminal" to set t to do script "\(cmd)" in front window
            else
                tell application "Terminal" to set t to do script "\(cmd)"
            end if

            """
        } else {
            s += "tell application \"Terminal\" to set t to do script \"\(cmd)\"\n"
        }
        s += "tell application \"Terminal\"\n"
        if let profile = terminalProfiles[theme] {
            s += "    try\n        set current settings of t to settings set \"\(profile)\"\n    end try\n"
        }
        s += "    try\n        set custom title of t to \"\(escape(title))\"\n    end try\n"
        s += "end tell\n"
        return s
    }

    // MARK: - iTerm2

    private static let itermColors: [ServerTheme: String] = [
        .red: "{14000, 1500, 1500}", .green: "{1500, 11000, 3000}", .blue: "{1500, 4000, 14000}",
    ]

    private static func itermScript(command: String, title: String, theme: ServerTheme) -> String {
        let running = isRunning("com.googlecode.iterm2")
        let color = itermColors[theme].map { "set background color to \($0)\n        " } ?? ""
        return """
        tell application "iTerm2"
            activate
            \(running ? "" : "repeat 30 times\n        if (count of windows) > 0 then exit repeat\n        delay 0.1\n    end repeat")
            if (count of windows) is 0 then
                set theWindow to (create window with default profile)
                set theSession to current session of theWindow
            else if \(running ? "true" : "false") then
                tell current window
                    set theTab to (create tab with default profile)
                    set theSession to current session of theTab
                end tell
            else
                set theSession to current session of current window
            end if
            tell theSession
                \(color)set name to "\(escape(title))"
                write text "\(escape(command))"
            end tell
        end tell
        """
    }

    // MARK: - Yardımcılar

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func execute(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError.scriptFailed("AppleScript derlenemedi")
        }
        script.executeAndReturnError(&error)
        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "bilinmeyen hata"
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw LaunchError.scriptFailed("Terminal'i kontrol etme izni yok. Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon'dan SSHManager'a izin ver.")
            }
            throw LaunchError.scriptFailed(message)
        }
    }

    /// AppleScript metin sabiti için kaçış.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
