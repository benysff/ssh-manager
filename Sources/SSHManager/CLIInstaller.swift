import Foundation
import SSHManagerKit

/// Terminalde `sshm` komutunu kullanılabilir yapar: uygulamaya bir kısayol bağlantısı (symlink)
/// oluşturur ve zsh için sekme tamamlamayı ~/.zshrc'ye ekler.
enum CLIInstaller {
    struct Result {
        let path: String
        let inPath: Bool
        let completionAdded: Bool
    }

    private static let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]
    private static let zshMarker = "# >>> sshm (SSHManager) >>>"

    /// Kuruluysa sshm'in yolu.
    static var installedPath: String? {
        for dir in candidates {
            let path = (Paths.expand(dir) as NSString).appendingPathComponent("sshm")
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
               URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == AppPaths.executable {
                return path
            }
        }
        return nil
    }

    static func install() throws -> Result {
        let fm = FileManager.default
        let dir = candidates.map(Paths.expand).first { fm.isWritableFile(atPath: $0) }
            ?? Paths.expand("~/.local/bin")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let link = (dir as NSString).appendingPathComponent("sshm")
        if fm.fileExists(atPath: link) || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            guard (try? fm.destinationOfSymbolicLink(atPath: link)) != nil else {
                throw NSError(domain: "SSHManager", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(link) zaten var ve SSHManager'a ait değil; üzerine yazılmadı."])
            }
            try fm.removeItem(atPath: link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: AppPaths.executable)

        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let inPath = pathDirs.contains(dir) || ["/opt/homebrew/bin", "/usr/local/bin"].contains(dir)
        return Result(path: link, inPath: inPath, completionAdded: addZshCompletion(extraPath: inPath ? nil : dir))
    }

    /// ~/.zshrc'ye (yoksa) sekme tamamlamayı ekler. Daha önce eklendiyse dokunmaz.
    private static func addZshCompletion(extraPath: String?) -> Bool {
        let zshrc = Paths.expand("~/.zshrc")
        let current = (try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? ""
        guard !current.contains(zshMarker) else { return false }
        var block = "\n\(zshMarker)\n"
        if let dir = extraPath { block += "export PATH=\"\(dir):$PATH\"\n" }
        block += """
        _sshm() { compadd -- ${(f)"$(sshm --complete 2>/dev/null)"} }
        (( $+functions[compdef] )) && compdef _sshm sshm
        # <<< sshm (SSHManager) <<<

        """
        guard let handle = FileHandle(forWritingAtPath: zshrc) ?? {
            FileManager.default.createFile(atPath: zshrc, contents: nil)
            return FileHandle(forWritingAtPath: zshrc)
        }() else { return false }
        handle.seekToEndOfFile()
        handle.write(Data(block.utf8))
        handle.closeFile()
        return true
    }
}

private extension Paths {
    static func expand(_ p: String) -> String { expandTilde(p) }
}
