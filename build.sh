#!/bin/zsh
# build.sh — собрать Lumen.app в ./build (и положить в /Applications с флагом --install)
set -e
cd "${0:A:h}"
APP=build/Lumen.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
env -u SDKROOT xcrun --sdk macosx swiftc -O -target arm64-apple-macos14 \
  src/*.swift -o "$APP/Contents/MacOS/Lumen"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.artsu.Lumen</string>
  <key>CFBundleName</key><string>Lumen</string>
  <key>CFBundleExecutable</key><string>Lumen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Прямое управление подсветкой XDR</string>
</dict></plist>
PLIST
# Подпись сертификатом разработчика: требование к подписи тогда привязано к
# идентификатору и сертификату, а не к хешу сборки, и Универсальный доступ
# не слетает после каждой пересборки. Нет сертификата — ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "подпись: ${IDENTITY:-ad-hoc}"
echo "собрано: $PWD/$APP"
if [[ "$1" == "--install" ]]; then
  pkill -x Lumen 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Lumen.app && cp -R "$APP" /Applications/ && echo "установлено: /Applications/Lumen.app"
  open /Applications/Lumen.app && echo "запущено"
fi
