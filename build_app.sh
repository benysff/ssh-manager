#!/bin/bash
# SSHManager'ı derleyip çalıştırılabilir bir .app paketine dönüştürür.
set -e

cd "$(dirname "$0")"

APP_NAME="SSHManager"
BUILD_CONFIG="release"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "==> Swift derleniyor (${BUILD_CONFIG})..."
swift build -c "${BUILD_CONFIG}"

BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)/${APP_NAME}"

echo "==> .app paketi oluşturuluyor..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

cp "${BIN_PATH}" "${MACOS}/${APP_NAME}"

cat > "${CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SSHManager</string>
    <key>CFBundleDisplayName</key>
    <string>SSH Manager</string>
    <key>CFBundleExecutable</key>
    <string>SSHManager</string>
    <key>CFBundleIdentifier</key>
    <string>com.yusuf.sshmanager</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menü bar uygulaması: Dock'ta görünme, ana pencere açma -->
    <key>LSUIElement</key>
    <true/>
    <!-- iTerm2'yi sürmek için otomasyon izni açıklaması -->
    <key>NSAppleEventsUsageDescription</key>
    <string>SSH Manager, sunucularınıza bağlanmak için iTerm2'yi kontrol eder.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc imzalanıyor (otomasyon izinleri için gerekli)..."
codesign --force --deep --sign - "${APP_DIR}"

echo ""
echo "✅ Hazır: ${APP_DIR}"
echo ""
echo "Çalıştırmak için:"
echo "    open \"${APP_DIR}\""
echo ""
echo "İlk çalıştırmada macOS, iTerm2'yi kontrol etme izni isteyecek — 'İzin Ver' de."
