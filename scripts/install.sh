#!/bin/bash
# Installs (or updates) Heartware from the latest release, then opens it.
#   curl -fsSL https://raw.githubusercontent.com/Olima34/Heartware/main/scripts/install.sh | bash
set -euo pipefail

REPO="Olima34/Heartware"
APP="Heartware.app"
BUNDLE_ID="io.github.olima34.cleanmyclaude"
# The file names of a copy installed before the app was called Heartware: replaced by Heartware.app, sent to the Trash.
OLD_APPS=("Clean My Claude.app" "Chamois.app")
# The Ed25519 public key of the published versions, the one the app checks its updates against
# (UpdatesSelfSignature.publicKey): base64 of its raw 32 bytes.
PUBLIC_KEY="BrZ97S0xVjos9xHFjqhiRzFXLLJAJdo9VTdGFTQX09w="
# Tests: HW_INSTALL_DIR installs elsewhere, without closing or opening the installed app; HW_ZIP_URL (and
# HW_SIG_URL, by default the same address followed by .sig) installs another archive.
TEST_DIR="${HW_INSTALL_DIR:-}"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Heartware est une app pour Mac." >&2
  exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then
  echo "Heartware demande macOS 14 Sonoma ou plus récent (tu as $(sw_vers -productVersion))." >&2
  exit 1
fi

# Where it goes: where it already is (update), else Applications, else the Applications folder of the user.
user_copy() {
  local name
  for name in "$APP" "${OLD_APPS[@]}"; do [[ -d "$HOME/Applications/$name" ]] && return 0; done
  return 1
}
if [[ -n "$TEST_DIR" ]]; then
  DEST="$TEST_DIR"
elif user_copy; then
  DEST="$HOME/Applications"
elif [[ -d "/Applications/$APP" || -w "/Applications" ]]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi

# The latest version, looked up once: the archive and its signature come from the same one.
TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
TAG="${TAG##*/}"
if [[ "$TAG" =~ ^v[0-9]+(\.[0-9]+)+$ ]]; then
  BASE="https://github.com/$REPO/releases/download/$TAG"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi
URL="${HW_ZIP_URL:-$BASE/Heartware.zip}"
SIG_URL="${HW_SIG_URL:-$URL.sig}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Téléchargement de Heartware…"
curl -fL --progress-bar "$URL" -o "$TMP/Heartware.zip"

# The signature: made by the key of the published versions, which never leaves GitHub's secrets. macOS's own
# openssl (LibreSSL) does not know Ed25519: OpenSSL 3 does it, when this Mac has it (Homebrew).
if [[ -n "$PUBLIC_KEY" ]]; then
  if ! curl -fsL "$SIG_URL" -o "$TMP/Heartware.zip.sig"; then
    echo "Cette version n'est pas accompagnée de sa signature (Heartware.zip.sig) : je ne l'installe pas." >&2
    exit 1
  fi
  printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' "$PUBLIC_KEY" > "$TMP/key.pem"
  OPENSSL=""
  for candidate in "$(command -v openssl || true)" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
                   /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    if [[ -n "$candidate" && -x "$candidate" ]] && "$candidate" pkey -pubin -in "$TMP/key.pem" -noout >/dev/null 2>&1; then
      OPENSSL="$candidate"
      break
    fi
  done
  if [[ -n "$OPENSSL" ]]; then
    if ! "$OPENSSL" base64 -d -A -in "$TMP/Heartware.zip.sig" -out "$TMP/signature" 2>/dev/null \
       || ! "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/key.pem" -rawin -in "$TMP/Heartware.zip" \
                       -sigfile "$TMP/signature" >/dev/null 2>&1; then
      echo "La signature de l'archive ne correspond pas à la clé de Heartware : je ne l'installe pas." >&2
      exit 1
    fi
    echo "→ Signature vérifiée."
  else
    echo "→ Signature Ed25519 non vérifiée ici (le openssl de macOS ne la connaît pas ; OpenSSL 3 de Homebrew, si. L'archive vient bien de GitHub en HTTPS). L'app vérifie elle-même ses prochaines mises à jour."
  fi
fi

# The archive holds one app, whatever its file name; it is installed as Heartware.app.
mkdir "$TMP/app"
ditto -x -k "$TMP/Heartware.zip" "$TMP/app"
UNPACKED=("$TMP"/app/*.app)
if [[ ${#UNPACKED[@]} -ne 1 || ! -d "${UNPACKED[0]}" ]]; then
  echo "L'archive téléchargée ne contient pas l'app : réessaie dans un instant." >&2
  exit 1
fi

# An open copy is closed first (it reopens at the end).
if [[ -z "$TEST_DIR" ]]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
fi

# Braces before "…": the bash of macOS (3.2) would read its first byte as part of the name in a UTF-8 locale.
echo "→ Installation dans ${DEST}…"
mkdir -p "$DEST"
rm -rf "${DEST:?}/$APP"
ditto "${UNPACKED[0]}" "$DEST/$APP"
for name in "${OLD_APPS[@]}"; do
  if [[ -d "$DEST/$name" ]]; then
    mv "$DEST/$name" "$HOME/.Trash/$name $(date +%H%M%S)" 2>/dev/null && echo "→ L'ancienne copie « $name » est dans la Corbeille."
  fi
done
# Downloaded by curl, the app carries no quarantine; this only matters if the archive did.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "✓ Heartware est installé. Il s'ouvre ; ensuite, ⌥Espace ouvre le lanceur depuis n'importe où."
[[ -z "$TEST_DIR" ]] && open "$DEST/$APP"
exit 0
