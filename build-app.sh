#!/bin/bash
# Sestaví SSHTool.app do ./build/
#   ./build-app.sh                  – ad-hoc podpis
#   SIGN_IDENTITY="Apple Development: Jan Novak (XXXX)" ./build-app.sh
#   ./build-app.sh --install        – navíc zkopíruje do /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SSHTool"
BUNDLE_ID="cz.local.sshtool"
VERSION="${VERSION_OVERRIDE:-0.26.10}"

# Aktualizace z GitHub Releases: owner/repo (env GITHUB_REPO > git remote origin) a veřejný klíč podpisu
UPDATE_REPO="${GITHUB_REPO:-}"
if [[ -z "$UPDATE_REPO" ]] && command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  UPDATE_REPO="$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
fi
[[ "$UPDATE_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || UPDATE_REPO="johnyvobruba/SSHTool"   # výchozí oficiální zdroj
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
IDENTITY="${SIGN_IDENTITY:--}"

# FreeRDP přibalený do aplikace (RDP bez „brew install freerdp“ u každého uživatele).
#   BUNDLE_FREERDP=auto (výchozí) – přibalí, pokud je na stroji freerdp + dylibbundler
#   BUNDLE_FREERDP=1 – vyžadováno (CI), BUNDLE_FREERDP=0 – nepřibalovat
if [[ "${BUNDLE_FREERDP:-auto}" != "0" ]]; then
  FRDP=""
  for c in sdl-freerdp sdl-freerdp3 sdl3-freerdp; do
    for d in /opt/homebrew/bin /usr/local/bin; do
      if [[ -x "$d/$c" ]]; then FRDP="$d/$c"; break 2; fi
    done
  done
  if [[ -n "$FRDP" ]] && command -v dylibbundler >/dev/null; then
    echo "▶ Přibaluji FreeRDP ($FRDP)…"
    # FreeRDP jako malá vnořená aplikace → okno RDP má v Docku ikonu a název SSHTool
    RA="$APP/Contents/Helpers/SSHTool-RDP.app"
    H="$RA/Contents/MacOS"
    FW="$RA/Contents/Frameworks"
    mkdir -p "$H" "$FW" "$RA/Contents/Resources"
    cp "$(realpath "$FRDP")" "$H/sdl-freerdp"
    chmod u+w "$H/sdl-freerdp"
    cat > "$RA/Contents/Info.plist" <<RPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME} RDP</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME} RDP</string>
  <key>CFBundleExecutable</key><string>sdl-freerdp</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.rdp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
RPLIST
    BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    SEARCH=(-s "$BREW_PREFIX/lib")
    for f in freerdp sdl3 sdl2 sdl3_ttf sdl2_ttf openssl@3 ffmpeg cjson jpeg-turbo krb5 libusb pkcs11-helper; do
      [[ -d "$BREW_PREFIX/opt/$f/lib" ]] && SEARCH+=(-s "$BREW_PREFIX/opt/$f/lib")
    done
    # dylibbundler zkopíruje závislé knihovny a přepíše cesty na @executable_path/../Frameworks/
    dylibbundler -of -b -x "$H/sdl-freerdp" -d "$FW" -p @executable_path/../Frameworks/ "${SEARCH[@]}" </dev/null >/dev/null
    # OpenSSL „legacy“ provider (MD4/RC4) – bez něj FreeRDP nemá NTLM, takže NLA/CredSSP
    # mimo doménu (Kerberos) selže. Načítá se dynamicky, dylibbundler ho nenajde → kopie ručně,
    # cesta se předává přes OPENSSL_MODULES při spuštění (RDP.swift).
    LEGACY="$BREW_PREFIX/opt/openssl@3/lib/ossl-modules/legacy.dylib"
    if [[ -f "$LEGACY" ]]; then
      mkdir -p "$FW/ossl-modules"
      cp "$(realpath "$LEGACY")" "$FW/ossl-modules/legacy.dylib"
      chmod u+w "$FW/ossl-modules/legacy.dylib"
      install_name_tool -id "@loader_path/legacy.dylib" "$FW/ossl-modules/legacy.dylib" 2>/dev/null || true
      # případné závislosti na libcrypto/libssl přesměrovat na přibalené kopie
      otool -L "$FW/ossl-modules/legacy.dylib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        b="$(basename "$dep")"
        if [[ "$dep" != /usr/lib/* && "$dep" != /System/* && "$dep" != @* && -f "$FW/$b" ]]; then
          install_name_tool -change "$dep" "@loader_path/../$b" "$FW/ossl-modules/legacy.dylib"
        fi
      done
      codesign --force --sign "$IDENTITY" "$FW/ossl-modules/legacy.dylib" 2>/dev/null
      echo "  + OpenSSL legacy provider (NTLM pro NLA)"
    elif [[ "${BUNDLE_FREERDP:-auto}" == "1" ]]; then
      echo "✗ Chybí $LEGACY (OpenSSL legacy provider, nutný pro NTLM/NLA)"; exit 1
    else
      echo "  ! OpenSSL legacy provider nenalezen – NLA přes NTLM nebude fungovat"
    fi
    # seznam knihoven do Resources hlavní aplikace (v Helpers smí být jen podepsaný kód)
    ls "$FW" > "$APP/Contents/Resources/FreeRDP-BUNDLED-LIBS.txt"
    for f in "$FW/"*.dylib; do codesign --force --sign "$IDENTITY" "$f" 2>/dev/null; done
    echo "  $(ls "$FW"/*.dylib | wc -l | tr -d ' ') knihoven, $(du -sh "$RA" | cut -f1)"
    # samotná vnořená aplikace se podepíše až po vytvoření ikony (níže)
  elif [[ "${BUNDLE_FREERDP:-auto}" == "1" ]]; then
    echo "✗ BUNDLE_FREERDP=1, ale chybí freerdp nebo dylibbundler (brew install freerdp dylibbundler)"; exit 1
  else
    echo "▶ FreeRDP se nepřibaluje (pro přibalení: brew install freerdp dylibbundler)"
  fi
fi
[[ -f THIRD-PARTY-NOTICES.md ]] && cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

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

# žádný soubor jen pro čtení (knihovny z Homebrew bývají 444) – jinak u uživatele nejde odstranit karanténa
chmod -R u+w "$APP"

echo "▶ Podepisuji (${IDENTITY})…"
RDP_APP="$APP/Contents/Helpers/SSHTool-RDP.app"
if [[ -d "$RDP_APP" ]]; then
  [[ -f "$APP/Contents/Resources/AppIcon.icns" ]] && cp "$APP/Contents/Resources/AppIcon.icns" "$RDP_APP/Contents/Resources/"
  codesign --force --sign "$IDENTITY" "$RDP_APP"
fi
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
