#!/bin/zsh
# Creates, once per Mac, the local signing certificate "Clean My Claude Dev", in a keychain of its own:
# ~/Library/Keychains/cleanmyclaude-signing.keychain-db, protected by its own password, locked at sleep and after
# 5 minutes, and left out of the keychain search list. Signed with it, every build keeps the same identity: macOS keeps
# the permissions (Full Disk Access, Accessibility, folders, automation…) from one rebuild to the next.
#
# Why a keychain of its own: in the session keychain, unlocked all session long with codesign allowed to use the key,
# any program run under the account could have codesign sign, without a window, a fake app with Heartware's
# identifier. It would have the same designated requirement as the real one, inherit the permissions given to
# Heartware and read its keychain items (the API key). Here codesign signs only once this keychain's password has
# been typed: scripts/build_app.sh and the app's updates ask for it, sign, then lock the keychain again.
#
# The certificate is self-signed and only exists on this Mac: it proves nothing to anybody else and changes no trust
# setting. Its private key is generated in memory (never written to disk), cannot be exported and only codesign may use
# it. A certificate made by an earlier version of this script, in the session keychain, is offered for removal.
# To remove everything later:
#   security delete-keychain ~/Library/Keychains/cleanmyclaude-signing.keychain-db
set -euo pipefail

NAME="Clean My Claude Dev"
KEYCHAIN="${HW_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/cleanmyclaude-signing.keychain-db}"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

# The SHA-1 of the "Clean My Claude Dev" identity in a keychain (read without unlocking it), or nothing.
identity_in() {
  [[ -f "$1" ]] || return 0
  security find-identity -p codesigning "$1" 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }'
}

# The keychain search list, one path per line.
search_list() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

if [[ ! -t 0 ]]; then
  echo "Lance ce script dans un Terminal : il te demande de choisir un mot de passe." >&2
  exit 1
fi

if [[ -n "$(identity_in "$KEYCHAIN")" ]]; then
  echo "✓ Le certificat « $NAME » est déjà dans son trousseau à part : rien à créer."
else
  echo "Le certificat « $NAME » sera rangé dans un trousseau à part, protégé par son propre mot de passe :"
  echo "  $KEYCHAIN"
  echo "Aucun programme ne pourra signer avec lui sans ce mot de passe. Choisis-en un que tu retiendras,"
  echo "différent de celui de ta session : il te sera demandé à chaque compilation et à chaque mise à jour de l'app."
  echo
  if [[ -f "$KEYCHAIN" ]]; then
    echo "→ Le trousseau existe déjà (création interrompue ?) : saisis son mot de passe pour le déverrouiller."
    security unlock-keychain "$KEYCHAIN"
  else
    before=("${(@f)$(search_list)}")
    security create-keychain "$KEYCHAIN"
    # Older versions of macOS add a new keychain to the search list: it stays out of it, so that no program finds the
    # identity by chance (codesign reaches it only through --keychain).
    after=("${(@f)$(search_list)}")
    if [[ "${after[*]}" != "${before[*]}" ]]; then
      security list-keychains -d user -s "${before[@]}"
    fi
  fi
  # Locked at sleep and after 5 minutes, even if a signing is interrupted before locking it.
  security set-keychain-settings -l -u -t 300 "$KEYCHAIN"

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"; security lock-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT
  cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

  echo "→ Création du certificat local « $NAME » (valable 10 ans)…"
  # The private key only lives in this script's memory and in pipes, never in a file another program could read.
  KEY="$(/usr/bin/openssl genrsa 2048 2>/dev/null)"
  CERT="$(/usr/bin/openssl req -x509 -new -key <(print -r -- "$KEY") -days 3650 -config "$WORK/cert.cnf" 2>/dev/null)"
  PASS="$(/usr/bin/openssl rand -hex 16)"
  echo "→ Ajout au trousseau de signature (clé non exportable, réservée à codesign)…"
  security import <(/usr/bin/openssl pkcs12 -export -inkey <(print -r -- "$KEY") -in <(print -r -- "$CERT") -name "$NAME" \
                      -passout "pass:$PASS" 2>/dev/null) \
    -f pkcs12 -k "$KEYCHAIN" -P "$PASS" -x -T /usr/bin/codesign >/dev/null
  unset KEY PASS
  security lock-keychain "$KEYCHAIN"
  HASH="$(identity_in "$KEYCHAIN")"
  if [[ -z "$HASH" ]]; then
    echo "✗ Le certificat n'apparaît pas dans le trousseau : rien n'est prêt. Relance le script." >&2
    exit 1
  fi
  echo "✓ Certificat prêt ($HASH), trousseau verrouillé."
fi

# An identity made by an earlier version of this script, in the session keychain: any program can still sign with it.
OLD="$(identity_in "$LOGIN")"
if [[ -n "$OLD" ]]; then
  echo
  echo "⚠︎ Un ancien certificat « $NAME » ($OLD) est encore dans ton trousseau de session."
  echo "  Tant qu'il y reste, n'importe quel programme lancé sous ton compte peut signer avec lui, sans fenêtre,"
  echo "  une fausse app qui hériterait des autorisations de Heartware. Sa clé ne peut pas être déplacée."
  echo "  Le supprimer ne touche à rien d'autre ; les copies de l'app signées avec lui (celle installée, par exemple)"
  echo "  seront re-signées avec le nouveau certificat à la prochaine compilation ou mise à jour, et macOS te"
  echo "  redemandera une dernière fois les autorisations (Réglages › Autorisations › Tout autoriser)."
  printf "  Supprimer l'ancien certificat du trousseau de session ? [o/N] "
  read -r answer
  if [[ "$answer" == [oOyY]* ]]; then
    security delete-identity -Z "$OLD" "$LOGIN"
    echo "✓ Ancien certificat supprimé du trousseau de session."
  else
    echo "  Gardé. Pour le supprimer plus tard : security delete-identity -Z $OLD ~/Library/Keychains/login.keychain-db"
  fi
fi

echo
echo "À la prochaine compilation (./scripts/build_app.sh) ou mise à jour de l'app, le mot de passe de ce trousseau"
echo "te sera demandé, puis il sera reverrouillé. Accorde ensuite les autorisations une dernière fois"
echo "(Réglages › Autorisations › Tout autoriser) : elles resteront acquises après chaque reconstruction."
