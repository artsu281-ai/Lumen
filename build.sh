#!/bin/zsh
# build.sh — собрать Lumen.app в ./build (и положить в /Applications с флагом --install)
set -e
cd "${0:A:h}"
# Собираем во временную папку: неудачная сборка не стирает прошлую рабочую.
APP=build/Lumen.app
NEW=build/.Lumen.new.app
rm -rf "$NEW"; mkdir -p "$NEW/Contents/MacOS"
env -u SDKROOT xcrun --sdk macosx swiftc -O -g -warnings-as-errors -target arm64-apple-macos14 \
  src/*.swift -o "$NEW/Contents/MacOS/Lumen"
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.artsu.Lumen</string>
  <key>CFBundleName</key><string>Lumen</string>
  <key>CFBundleExecutable</key><string>Lumen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Прямое управление подсветкой XDR</string>
</dict></plist>
PLIST
# Подпись сертификатом разработчика: требование к подписи тогда привязано к
# идентификатору и сертификату, а не к хешу сборки, и Универсальный доступ
# не слетает после каждой пересборки. Нет сертификата — ad-hoc.
# Сертификат берётся по отпечатку SHA-1, а не по имени: после продления
# двух с одним именем codesign не различит. LUMEN_IDENTITY — выбрать свой.
IDENTITY=${LUMEN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}
codesign --force --options runtime --sign "${IDENTITY:--}" "$NEW"
if [[ -n "$IDENTITY" ]]; then
  echo "подпись: $(security find-identity -v -p codesigning | awk -F'"' -v id="$IDENTITY" '$0 ~ id {print $2; exit}')"
else
  echo "подпись: ad-hoc — ВНИМАНИЕ: Универсальный доступ слетит после каждой пересборки"
fi
rm -rf "$APP" && mv "$NEW" "$APP"
echo "собрано: $PWD/$APP"
if [[ "$1" == "--install" ]]; then
  # выходя, Lumen возвращает пресет — ждём, пока он закончит, иначе новый
  # запуск примет чужой пресет за исходный
  pkill -x Lumen 2>/dev/null || true
  for i in {1..50}; do pgrep -x Lumen >/dev/null || break; sleep 0.2; done
  sleep 0.5   # смена пресета досчитывается и после выхода процесса
  rm -rf /Applications/Lumen.app && cp -R "$APP" /Applications/ && echo "установлено: /Applications/Lumen.app"
  open /Applications/Lumen.app && echo "запущено"
fi
