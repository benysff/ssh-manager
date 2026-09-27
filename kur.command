#!/bin/bash
# SSHManager kurulumu: derler, .app paketi oluşturur ve Uygulamalar klasörüne kurar.
#   ./kur.command                 derle + kur + aç
#   ./kur.command --sadece-derle  sadece build/SSHManager.app üret
set -e
cd "$(dirname "$0")"

APP_NAME="SSHManager"
VERSION="2.0.0"
APP_DIR="build/${APP_NAME}.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "✗ Swift bulunamadı. Terminalde şunu çalıştır, sonra tekrar dene:  xcode-select --install"
  exit 1
fi

echo "▸ Derleniyor (Apple Silicon + Intel, ilk seferde 1-2 dakika)…"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|warning: .*\.swift|Compiling|Build complete" || true
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
[ -x "${BIN_DIR}/${APP_NAME}" ] || { echo "✗ Derleme başarısız."; exit 1; }

echo "▸ Uygulama paketi hazırlanıyor…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp assets/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>SSHManager</string>
    <key>CFBundleDisplayName</key>          <string>SSH Manager</string>
    <key>CFBundleExecutable</key>           <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>           <string>com.yusuf.sshmanager</string>
    <key>CFBundleVersion</key>              <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- Menü çubuğu uygulaması: Dock'ta görünmez -->
    <key>LSUIElement</key>                  <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SSH Manager, bağlantıları Terminal veya iTerm2'de açmak için bu uygulamaları kontrol eder.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>      <string>SSHManager</string>
            <key>CFBundleURLSchemes</key>   <array><string>sshmanager</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc imza: otomasyon (Terminal'i kontrol etme) izinleri için gerekli.
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1
echo "✓ Derlendi: ${APP_DIR}"

[ "$1" = "--sadece-derle" ] && exit 0

# /Applications yazılabilirse oraya, değilse ~/Applications'a kur. Çalışan sürümü kapat.
TARGET="/Applications"
[ -w "$TARGET" ] || { TARGET="$HOME/Applications"; mkdir -p "$TARGET"; }
osascript -e 'tell application id "com.yusuf.sshmanager" to quit' >/dev/null 2>&1 || true
pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
sleep 1
rm -rf "${TARGET}/${APP_NAME}.app"
cp -R "${APP_DIR}" "${TARGET}/"
echo "✓ Kuruldu: ${TARGET}/${APP_NAME}.app"
open "${TARGET}/${APP_NAME}.app"
echo "  Menü çubuğunda terminal simgesi belirdi. Hızlı bağlan: ⌃⌥S"
