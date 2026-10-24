#!/bin/zsh
# Creates, once, the certificate that signs the published versions ("Heartware") and gives it to GitHub: the CI
# (.github/workflows/build.yml and release.yml) signs every version with it. Every version then has the same designated
# requirement, the one macOS ties the permissions (Full Disk Access, Accessibility…) and the app's keychain items to:
# an update keeps them, nothing to type.
#
# The certificate is self-signed: it proves nothing to Gatekeeper and changes no trust setting, only that every version
# comes from the same hands. Its private key is generated in memory, goes straight to the secret CMC_CODESIGN_IDENTITY of
# the GitHub environment "release" (like CMC_UPDATE_KEY) and is kept nowhere else: not on this Mac, not in the repository.
# Its SHA-1 is written in Features/Updates/UpdatesSelfSigning.swift (releaseCertificate), where the CI checks it.
# Needs gh, signed in with the right to change the repository's secrets.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
NAME="Clean My Claude"
SECRET="CMC_CODESIGN_IDENTITY"
ENVIRONMENT="release"
SOURCE="Sources/Heartware/Features/Updates/UpdatesSelfSigning.swift"

cert_in() { sed -nE 's/^ *static let releaseCertificate: String\? = "([0-9A-F]{40})".*/\1/p' "$SOURCE"; }

if ! command -v gh >/dev/null; then
  echo "✗ Il faut l'outil gh de GitHub (brew install gh), connecté avec gh auth login." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "✗ gh n'est pas connecté à GitHub : lance gh auth login, puis relance ce script." >&2
  exit 1
fi
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
CURRENT="$(cert_in)"
if gh secret list --env "$ENVIRONMENT" --repo "$REPO" | awk '{print $1}' | grep -qx "$SECRET"; then
  if [[ -n "$CURRENT" ]]; then
    echo "✓ Le certificat de publication ($CURRENT) est déjà dans les secrets de $REPO : rien à faire."
    exit 0
  fi
  echo "✗ Le secret $SECRET existe déjà dans $REPO, mais $SOURCE ne nomme pas son certificat," >&2
  echo "  et GitHub ne rend jamais un secret. Supprime-le, puis relance ce script :" >&2
  echo "    gh secret delete $SECRET --env $ENVIRONMENT --repo $REPO" >&2
  exit 1
fi
if [[ -n "$CURRENT" ]]; then
  echo "⚠︎ $SOURCE nomme déjà un certificat ($CURRENT), mais sa clé n'est plus dans les secrets de $REPO."
  echo "  En créer un nouveau change l'identité des versions publiées : macOS redemandera une fois les autorisations"
  echo "  à chaque copie installée, à sa prochaine mise à jour."
  printf "  Créer un nouveau certificat ? [o/N] "
  read -r answer
  [[ "$answer" == [oOyY]* ]] || { echo "  Rien n'a changé."; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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

echo "→ Création du certificat de publication « $NAME » (valable 20 ans)…"
# The private key only lives in this script's memory and in pipes, never in a file another program could read.
KEY="$(/usr/bin/openssl genrsa 3072 2>/dev/null)"
CERT="$(/usr/bin/openssl req -x509 -new -key <(print -r -- "$KEY") -days 7300 -config "$WORK/cert.cnf" 2>/dev/null)"
# What codesign writes in the designated requirement: certificate leaf = H"<SHA-1 of the certificate>".
HASH="$(print -r -- "$CERT" | /usr/bin/openssl x509 -noout -fingerprint -sha1 | sed -e 's/.*=//' -e 's/://g' | tr a-f A-F)"
if [[ ! "$HASH" =~ '^[0-9A-F]{40}$' ]]; then
  echo "✗ Certificat illisible : rien n'a été envoyé à GitHub." >&2
  exit 1
fi

echo "→ Envoi au secret $SECRET de l'environnement « $ENVIRONMENT » de ${REPO}…"
# Read by gh on its standard input: never on a command line, which any program can list.
print -r -- "$CERT"$'\n'"$KEY" | gh secret set "$SECRET" --env "$ENVIRONMENT" --repo "$REPO"
unset KEY

sed -i '' -E "s/^( *static let releaseCertificate: String\\? = ).*\$/\\1\"$HASH\"/" "$SOURCE"
if [[ "$(cert_in)" != "$HASH" ]]; then
  echo "✗ Le secret est envoyé, mais je n'ai pas pu écrire $HASH dans $SOURCE (releaseCertificate) : écris-le à la main." >&2
  exit 1
fi

echo "✓ Certificat de publication prêt ($HASH)."
echo "  Il est nommé dans $SOURCE : commite et pousse ce changement. La version suivante sera signée avec lui ;"
echo "  macOS redemandera une dernière fois les autorisations après cette mise à jour, puis les gardera."
