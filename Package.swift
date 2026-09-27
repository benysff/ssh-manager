// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SSHManager",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Arayüzden bağımsız, test edilebilir çekirdek: model, ssh komutu, config okuma.
        .target(
            name: "SSHManagerKit",
            path: "Sources/SSHManagerKit"
        ),
        // Menü çubuğu uygulaması + komut satırı (sshm) + askpass yardımcısı tek dosyada.
        .executableTarget(
            name: "SSHManager",
            dependencies: ["SSHManagerKit"],
            path: "Sources/SSHManager"
        ),
        .testTarget(
            name: "SSHManagerKitTests",
            dependencies: ["SSHManagerKit"],
            path: "Tests/SSHManagerKitTests"
        ),
        // Uzak betik testleri (sağlık, güncelleme, sudo, komut kütüphanesi). Komut Satırı Araçları'nda
        // "TestingMacros not found" hatası için README'deki -plugin-path notuna bak.
        .testTarget(
            name: "SSHManagerKitScriptTests",
            dependencies: ["SSHManagerKit"],
            path: "Tests/SSHManagerKitScriptTests"
        ),
    ]
)
