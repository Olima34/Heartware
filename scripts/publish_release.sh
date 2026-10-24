#!/bin/bash
# Publishes an app already built for the checked-out commit as a version on the Releases page, with the commits since
# the previous version as notes. Run by the CI: .github/workflows/build.yml after every green push on main,
# release.yml for a vX.Y.Z tag pushed by hand. Needs GH_TOKEN. The archive's signature, <archive>.sig (made by the
# workflow with the secret CMC_UPDATE_KEY), is published next to it.
# Usage: ./scripts/publish_release.sh 0.3.6 [build/Heartware.zip [other files to attach…]]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?numéro de version attendu, par exemple 0.3.6}"
ZIP="${2:-build/Heartware.zip}"
SIG="$ZIP.sig"
TAG="v$VERSION"
REPO="${GITHUB_REPOSITORY:-Olima34/Heartware}"
COMMIT="$(git rev-parse HEAD)"
ASSETS=("$ZIP")
EXTRA=("${@:3}")
# Once the app carries a public key (UpdatesSelfSignature.publicKey), every installed copy refuses a version without
# a valid signature: better to publish nothing.
if [[ -f "$SIG" ]]; then
  if ! grep -Eqx '[A-Za-z0-9+/]{86}==' "$SIG"; then
    echo "$SIG n'est pas une signature Ed25519 en base64 : rien n'est publié." >&2
    exit 1
  fi
  ASSETS+=("$SIG")
elif grep -Eq '^ *static let publicKey: String\? = "' Sources/Heartware/Features/Updates/UpdatesSelf.swift; then
  echo "$SIG manque alors que l'app exige une signature : rien n'est publié." >&2
  exit 1
fi
for f in ${EXTRA[@]+"${EXTRA[@]}"}; do
  [[ -f "$f" ]] || { echo "$f introuvable : rien n'est publié." >&2; exit 1; }
  ASSETS+=("$f")
done
# The previous version: the highest vX.Y.Z tag strictly before this commit.
PREVIOUS="$(git tag --merged HEAD --no-contains HEAD --list 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n 1p || true)"

NOTES="$(mktemp)"
{
  cat <<'NOTES'
**Installer en une ligne** (Terminal) :

```bash
curl -fsSL https://raw.githubusercontent.com/Olima34/Heartware/main/scripts/install.sh | bash
```

Ou télécharge **Heartware.zip** ci-dessous, glisse l'app dans Applications, puis au premier lancement :
Réglages Système › Confidentialité et sécurité › « Ouvrir quand même ». Déjà installée, l'app te propose elle-même cette version.

macOS 14 Sonoma ou plus récent, Apple Silicon et Intel.
NOTES
  if [[ -n "$PREVIOUS" ]]; then
    echo
    echo "## Ce qui change depuis la ${PREVIOUS#v}"
    echo
    git log --no-merges --format="- %s ([%h](https://github.com/$REPO/commit/%H))" "$PREVIOUS..HEAD"
  fi
} > "$NOTES"

# GitHub adds its own notes below (merged pull requests, link to the full comparison).
ARGS=(--target "$COMMIT" --title "Heartware $VERSION" --notes-file "$NOTES" --generate-notes)
[[ -n "$PREVIOUS" ]] && ARGS+=(--notes-start-tag "$PREVIOUS")
# With assets, gh creates the release as a draft and publishes it once they are all uploaded.
gh release create "$TAG" "${ASSETS[@]}" "${ARGS[@]}"
