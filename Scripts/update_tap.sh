#!/bin/bash
# After a release: points the Homebrew cask (github.com/arthur-bump-pm/homebrew-tap) at the new version, using the
# checksum Scripts/package_release.sh wrote, and pushes it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/Awake/Info.plist)
SUM_FILE="build/Awake-$VERSION.zip.sha256"
[[ -f "$SUM_FILE" ]] || { echo "No $SUM_FILE: run Scripts/package_release.sh first." >&2; exit 1; }
SHA=$(cut -d' ' -f1 "$SUM_FILE")
PUBLISHED=$(curl -fsSL "https://github.com/arthur-bump-pm/awake-mac/releases/download/v$VERSION/Awake-$VERSION.zip.sha256" | cut -d' ' -f1)
[[ "$SHA" == "$PUBLISHED" ]] || { echo "The v$VERSION release's checksum doesn't match $SUM_FILE: publish the release first." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git clone -q https://github.com/arthur-bump-pm/homebrew-tap.git "$WORK"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$WORK/Casks/awake.rb"
if git -C "$WORK" diff --quiet; then
    echo "The cask is already at $VERSION."
    exit 0
fi
git -C "$WORK" -c user.email="$(git config user.email)" -c user.name="$(git config user.name)" \
    commit -qam "Awake $VERSION"
git -C "$WORK" push -q origin main
echo "homebrew-tap now installs Awake $VERSION."
