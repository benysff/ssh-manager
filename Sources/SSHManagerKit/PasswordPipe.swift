import Foundation

/// Uygulamanın zaten bildiği parolayı, başlattığı ssh'ın askpass yardımcısına Anahtar Zinciri'ne gitmeden verir.
///
/// Toplu işlerde (100 sunucuda güncelleme kontrolü gibi) her askpass süreci Anahtar Zinciri'ni ayrı ayrı okusaydı
/// macOS izni süreç başına sorabilirdi. Bunun yerine uygulama kasayı bir kez açar ve parolayı tek kullanımlık bir
/// adlandırılmış boruya (FIFO) yazar. Parola diske yazılmaz (boru çekirdek belleğinde durur), boru kullanıcının
/// kendi geçici klasöründedir (başkaları erişemez) ve askpass okuyunca silinir.
public final class PasswordPipe {
    public let path: String
    private var fd: Int32

    /// Boruyu oluşturup parolayı içine yazar. Olmazsa nil (askpass eski usul Anahtar Zinciri'ne bakar).
    public init?(password: String, directory: String = NSTemporaryDirectory()) {
        let path = (directory as NSString).appendingPathComponent("sshmanager-\(UUID().uuidString).fifo")
        guard mkfifo(path, 0o600) == 0 else { return nil }
        // O_RDWR: okuyan yokken de açılabilir (beklemez); veri, askpass okuyana kadar boruda durur.
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { unlink(path); return nil }
        let bytes = Array((password + "\n").utf8)
        let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { Darwin.close(fd); unlink(path); return nil }
        self.path = path
        self.fd = fd
    }

    /// ssh bitince çağrılır: okunmadıysa parolayı boruyla birlikte yok eder.
    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
        unlink(path)
    }

    deinit { close() }

    /// askpass tarafı: borudaki parolayı alır ve boruyu siler (ikinci deneme aynı parolayı alamaz).
    /// Yol bir FIFO değilse ya da bu kullanıcıya ait değilse hiçbir şey yapmaz (ortam değişkeniyle
    /// rastgele bir dosyayı sildirmek mümkün olmasın).
    public static func take(path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFIFO, st.st_uid == getuid() else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        unlink(path)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(UInt8(ascii: "\n")) {
            let n = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            data += buffer[0..<n]
        }
        guard let line = String(bytes: data, encoding: .utf8)?.split(separator: "\n", omittingEmptySubsequences: false).first,
              !line.isEmpty else { return nil }
        return String(line)
    }
}
