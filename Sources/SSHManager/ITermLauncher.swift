import Foundation
import AppKit

/// iTerm2'yi AppleScript ile sürerek SSH oturumu açar.
///
/// Davranış:
///  - iTerm2'nin açık bir penceresi yoksa yeni pencere açar.
///  - Açık penceresi varsa o pencereye YENİ SEKME ekler (yeni pencere AÇMAZ).
///  - ssh komutunu yazar; parola Keychain'de varsa prompt gelince otomatik girer.
enum ITermLauncher {

    enum LaunchError: Error, LocalizedError {
        case scriptFailed(String)
        var errorDescription: String? {
            switch self {
            case .scriptFailed(let msg): return "iTerm2 başlatılamadı: \(msg)"
            }
        }
    }

    /// Verilen sunucuya bağlanır.
    static func connect(to server: Server) throws {
        let password = KeychainHelper.readPassword(account: server.keychainAccount)
        let script = buildScript(for: server, password: password)

        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            throw LaunchError.scriptFailed("AppleScript derlenemedi")
        }
        apple.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "bilinmeyen hata"
            throw LaunchError.scriptFailed(msg)
        }
    }

    // MARK: - Script üretimi

    private static func buildScript(for server: Server, password: String?) -> String {
        // ssh komutunu kur. StrictHostKeyChecking kapatmıyoruz; ilk bağlantıda
        // host key onayı kullanıcıya sorulur (güvenli davranış).
        var sshCommand = "ssh -p \(server.port) \(server.sshDestination)"
        if !server.postCommand.isEmpty {
            // Bağlantı sonrası komutu uzak kabukta çalıştırıp interaktif kabukta kal.
            let remote = escapeForDoubleQuotedShell(server.postCommand)
            sshCommand += " -t \"\(remote); exec \\$SHELL -l\""
        }

        let sshLine = escapeForAppleScript(sshCommand)

        // Parola otomasyonu: prompt gelince yaz. Parola yoksa bu blok atlanır.
        let passwordBlock: String
        if let password = password, !password.isEmpty {
            let escaped = escapeForAppleScript(password)
            passwordBlock = """
                    -- Parola promptunu bekle (en fazla ~20 sn), gelince Keychain parolasını yaz.
                    -- Sadece parola/passphrase prompt'una bakarız; shell prompt karakterlerine (% $ #) BAKMAYIZ,
                    -- aksi halde lokal kabuğun "%" promptu yanlışlıkla çıkışı tetikler.
                    repeat 40 times
                        delay 0.5
                        set theText to (text of theSession)
                        if theText contains "assword:" or theText contains "assword for" or theText contains "assphrase" then
                            write theSession text "\(escaped)"
                            exit repeat
                        end if
                        if theText contains "Permission denied" then exit repeat
                    end repeat
            """
        } else {
            passwordBlock = "                    -- Parola kayıtlı değil; kullanıcı elle girecek"
        }

        // Çekirdek mantık: pencere var mı? Varsa sekme ekle, yoksa pencere aç.
        return """
        tell application "iTerm2"
            activate
            if (count of windows) is 0 then
                set theWindow to (create window with default profile)
                set theSession to current session of theWindow
            else
                tell current window
                    set theTab to (create tab with default profile)
                    set theSession to current session of theTab
                end tell
            end if

            tell theSession
                write text "\(sshLine)"
            end tell

        \(passwordBlock)
        end tell
        """
    }

    /// AppleScript string literali için kaçış (çift tırnak ve ters bölü).
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Çift tırnaklı shell argümanı için kaçış.
    private static func escapeForDoubleQuotedShell(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
