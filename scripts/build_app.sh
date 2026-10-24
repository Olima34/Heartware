#!/bin/zsh
# Builds the app, shown by macOS as "Chamois", in its bundle "Clean My Claude.app" (release), and installs it in ~/Applications.
# Usage: ./scripts/build_app.sh [--no-install] [--zip] [--universal] [--binary=<chemin>]
#   --universal : Apple Silicon et Intel dans la même app (pour les versions publiées).
#   --binary=<chemin> : un exécutable déjà compilé (la CI compile chaque architecture sur sa machine, puis les réunit).
#   CMC_VERSION=0.3.0 : numéro de version (sinon celui de scripts/version.sh : dernière étiquette vX.Y.Z + commits depuis).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

EXEC="CleanMyClaude"
# What macOS shows (menu bar, Dock, Finder, System Settings), and the bundle's file name: the versions already installed
# look for "Clean My Claude.app" in the archive to update themselves, so the file keeps that name for now; the Finder
# and the Dock still show "Chamois" (a localized display name, like Apple's own apps).
DISPLAY_NAME="Chamois"
BUNDLE_NAME="Clean My Claude"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$BUNDLE_NAME.app"
# The version: CMC_VERSION (the CI passes the one it publishes), else that of this commit: the latest vX.Y.Z tag plus
# the commits since, the number the CI gives the same commit.
VERSION="${CMC_VERSION:-$("$ROOT/scripts/version.sh")}"
# The commit the app is built from: compared with GitHub, it tells which changes a new version brings.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
COMMIT_KEY=""
[[ -n "$COMMIT" ]] && COMMIT_KEY="<key>CMCCommit</key><string>$COMMIT</string>"
INSTALL=1
ZIP=0
UNIVERSAL=0
BINARY=""
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --zip) ZIP=1 ;;
    --universal) UNIVERSAL=1 ;;
    --binary=*) BINARY="${arg#--binary=}" ;;
  esac
done

if [[ -n "$BINARY" ]]; then
  [[ -x "$BINARY" ]] || { echo "✗ Pas d'exécutable en $BINARY" >&2; exit 1; }
  BIN="${BINARY:A}"
  echo "→ Version $VERSION${COMMIT:+ (${COMMIT[1,7]})}, compilée à part : $(lipo -archs "$BIN")"
else
  echo "→ Compilation (release) de la version $VERSION${COMMIT:+ (${COMMIT[1,7]})}…"
  ARCHS=()
  [[ $UNIVERSAL -eq 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
  swift build -c release "${ARCHS[@]}"
  BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$EXEC"
fi

echo "→ Vérification des garde-fous…"
"$BIN" --selftest
"$BIN" --selftest --demo

echo "→ Icône…"
ICON_WORK="$BUILD_DIR/icon"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK/AppIcon.iconset"
swift "$ROOT/scripts/make_icon.swift" "$ICON_WORK/icon-1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_WORK/icon-1024.png" --out "$ICON_WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICON_WORK/icon-1024.png" --out "$ICON_WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$ICON_WORK/AppIcon.icns"
# From macOS 26 on, the icon also has its dark version (design/icone/AppIcon.icon): Xcode 26's actool compiles it into
# Assets.car; an older actool cannot, and the app keeps the .icns alone.
ICON_NAME_KEY=""
mkdir -p "$ICON_WORK/car"
xcrun actool --compile "$ICON_WORK/car" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_WORK/car/partial.plist" "$ROOT/design/icone/AppIcon.icon" >/dev/null 2>&1 || true
if [[ -f "$ICON_WORK/car/Assets.car" ]]; then
  ICON_NAME_KEY="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "  (actool ne sait pas compiler AppIcon.icon : icône claire seule)"
fi

echo "→ Assemblage de $BUNDLE_NAME.app ($DISPLAY_NAME)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp "$ICON_WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "$ICON_NAME_KEY" ]]; then cp "$ICON_WORK/car/Assets.car" "$APP/Contents/Resources/Assets.car"; fi
# The name the Finder, the Dock and System Settings show (LSHasLocalizedDisplayName). macOS uses it only while the file
# name matches the Info.plist's own CFBundleDisplayName (otherwise it takes the bundle for one the user renamed): that
# one is the file name, these are "Chamois".
for lang in fr en; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  printf 'CFBundleDisplayName = "%s";\nCFBundleName = "%s";\n' "$DISPLAY_NAME" "$DISPLAY_NAME" \
    > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$BUNDLE_NAME</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleIdentifier</key><string>io.github.olima34.cleanmyclaude</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  $COMMIT_KEY
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ICON_NAME_KEY
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>$DISPLAY_NAME pilote le Finder, Événements système et ton navigateur pour vider la Corbeille, basculer le mode sombre, redémarrer, éteindre ou détacher la vidéo que tu regardes, uniquement quand tu le demandes.</string>
  <key>NSLocationUsageDescription</key><string>macOS n'indique le nom du réseau Wi-Fi qu'aux apps autorisées à utiliser la localisation. Ta position n'est ni lue ni enregistrée.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS n'indique le nom du réseau Wi-Fi qu'aux apps autorisées à utiliser la localisation. Ta position n'est ni lue ni enregistrée.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Pour mesurer la latence de ta box et des appareils de ton réseau, à ta demande.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Pour mesurer, ranger ou convertir les fichiers de ton Bureau, à ta demande.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Pour mesurer, ranger ou convertir tes documents, à ta demande.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Pour repérer les installeurs oubliés et ranger tes téléchargements, à ta demande.</string>
  <key>NSPhotoLibraryUsageDescription</key><string>$DISPLAY_NAME supprime de ta photothèque les photos et vidéos de ton iPhone que tu as triées, seulement à ta demande. macOS te demande de confirmer chaque suppression.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Convertir avec $DISPLAY_NAME</string></dict>
      <key>NSMessage</key><string>convertFiles</string>
      <key>NSPortName</key><string>$DISPLAY_NAME</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>io.github.olima34.cleanmyclaude</string>
      <key>CFBundleURLSchemes</key><array><string>cleanmyclaude</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Fichier à convertir</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>Libre et gratuit — MIT</string>
</dict>
</plist>
PLIST

# Signature. With a stable identity, macOS keeps the permissions (Full Disk Access, Accessibility, folders…)
# from one rebuild to the next. In order: CMC_SIGN_IDENTITY if set, else the local certificate made by
# scripts/setup_signing.sh ("Clean My Claude Dev", in its own locked keychain), else the same certificate made by an
# earlier version of that script in the session keychain, else ad hoc (macOS then forgets the permissions at every rebuild).
IDENTITY="${CMC_SIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${CMC_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/cleanmyclaude-signing.keychain-db}"
KEYCHAIN_ARGS=()
# The SHA-1 of the local certificate (it is self-signed, hence "not trusted": codesign accepts it by its hash).
local_identity() { security find-identity -p codesigning "$@" 2>/dev/null | awk '/"Clean My Claude Dev"/ {print $2; exit}'; }
if [[ -z "$IDENTITY" && -f "$SIGN_KEYCHAIN" ]]; then
  IDENTITY="$(local_identity "$SIGN_KEYCHAIN")"
  [[ -n "$IDENTITY" ]] && KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(local_identity)"
  if [[ -n "$IDENTITY" ]]; then
    echo "  ⚠︎ Le certificat « Clean My Claude Dev » est dans ton trousseau de session : n'importe quel programme peut"
    echo "    signer avec lui sans te demander. Relance ./scripts/setup_signing.sh pour le ranger dans un trousseau à part."
  fi
fi
# Hardened runtime: macOS refuses any library injected through DYLD_* variables or code patched in memory, so no other
# program borrows the permissions the user gave the app. Apple Events (Finder, System Events) stay allowed by entitlement.
ENTITLEMENTS="$(mktemp -d)/entitlements.plist"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.personal-information.photos-library</key><true/>
</dict>
</plist>
ENT
if [[ -n "$IDENTITY" ]]; then
  echo "→ Signature stable (les autorisations de macOS sont conservées)…"
  if (( ${#KEYCHAIN_ARGS} )); then
    # Locked again right after signing, and whatever happens (Ctrl-C, failure): codesign can sign without a window
    # only while it is unlocked.
    trap 'security lock-keychain "$SIGN_KEYCHAIN" 2>/dev/null || true' EXIT
    echo "  Mot de passe du trousseau de signature (celui choisi avec setup_signing.sh) :"
    # Typed in the Terminal without echo (three tries), otherwise read on the standard input. Never on the command line,
    # which any program can list, and never through macOS's own window, which does not show in every context.
    tries=0
    until security unlock-keychain "$SIGN_KEYCHAIN"; do
      [[ -t 0 ]] && (( ++tries < 3 )) && continue
      echo "✗ Trousseau de signature resté verrouillé : l'app n'est ni signée ni installée." >&2
      echo "  Lance ./scripts/build_app.sh dans un Terminal pour saisir son mot de passe." >&2
      exit 1
    done
  fi
  if ! codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" "${KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" "$APP"; then
    echo "✗ Signature impossible : l'app n'est pas installée." >&2
    exit 1
  fi
  (( ${#KEYCHAIN_ARGS} )) && security lock-keychain "$SIGN_KEYCHAIN"
else
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP" >/dev/null 2>&1 || true
  echo "  Astuce : lance une fois ./scripts/setup_signing.sh pour ne plus redonner les autorisations après chaque compilation."
fi
rm -f "$ENTITLEMENTS"

if [[ $ZIP -eq 1 ]]; then
  (cd "$BUILD_DIR" && rm -f CleanMyClaude.zip && ditto -c -k --keepParent "$BUNDLE_NAME.app" CleanMyClaude.zip)
  echo "✓ Archive : $BUILD_DIR/CleanMyClaude.zip"
fi

if [[ $INSTALL -eq 1 ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/$BUNDLE_NAME.app"
  cp -R "$APP" "$DEST/"
  # Register the app and its Finder service right away.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$BUNDLE_NAME.app" >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  echo "✓ Installée dans $DEST/$BUNDLE_NAME.app"
else
  echo "✓ App prête : $APP"
fi
