#!/bin/bash
# Sestaví SSHTool.app do ./build/
#   ./build-app.sh                  – ad-hoc podpis
#   SIGN_IDENTITY="Apple Development: Jan Novak (XXXX)" ./build-app.sh
#   ./build-app.sh --install        – navíc zkopíruje do /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SSHTool"
BUNDLE_ID="cz.local.sshtool"
VERSION="${VERSION_OVERRIDE:-0.24.1}"

# Aktualizace z GitHub Releases: owner/repo (env GITHUB_REPO > git remote origin) a veřejný klíč podpisu
UPDATE_REPO="${GITHUB_REPO:-}"
if [[ -z "$UPDATE_REPO" ]] && command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  UPDATE_REPO="$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
fi
[[ "$UPDATE_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || UPDATE_REPO=""
UPDATE_PUBKEY=""
[[ -f update-public-key.txt ]] && UPDATE_PUBKEY="$(tr -d ' \n\r' < update-public-key.txt)"
APP="build/${APP_NAME}.app"

command -v swift >/dev/null || { echo "Chybí Swift – nainstaluj Xcode nebo: xcode-select --install"; exit 1; }

echo "▶ Kompiluji (release, $(uname -m))…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "▶ Skládám ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/cs.lproj"   # čeština = jazyk aplikace (systémové menu, titulky oken)
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"

# Ikona: Resources/AppIcon.png (1024×1024) → AppIcon.icns přes sips + iconutil (součást macOS)
ICON_PLIST=""
if [[ -f Resources/AppIcon.png ]]; then
  echo "▶ Ikona…"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s           Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UIDesignRequiresCompatibility</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>cs</string>
  <key>CFBundleLocalizations</key><array><string>cs</string></array>
  <key>SSHToolUpdateRepo</key><string>${UPDATE_REPO}</string>
  <key>SSHToolUpdatePublicKey</key><string>${UPDATE_PUBKEY}</string>
  <key>NSHumanReadableCopyright</key><string>Vytvořil Jan Vobruba · Claude · Vibecoding</string>
  ${ICON_PLIST}
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
echo "▶ Podepisuji (${IDENTITY})…"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

[[ -n "$UPDATE_REPO" ]] && echo "▶ Aktualizace: github.com/${UPDATE_REPO}" || echo "▶ Aktualizace: vypnuté (repo není nastavené)"

if [[ "${1:-}" == "--install" ]]; then
  echo "▶ Instaluji do /Applications…"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  touch "/Applications/${APP_NAME}.app"   # ať Finder/Dock načte novou ikonu
  echo "✔ Hotovo: /Applications/${APP_NAME}.app"
else
  echo "✔ Hotovo: $(pwd)/${APP}   (spustíš: open \"${APP}\")"
fi
