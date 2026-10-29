#!/bin/bash
# Installs or updates Awake from its latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/arthur-bump-pm/awake-mac/main/install.sh | bash
#
# It downloads the release zip, checks it against the release's SHA-256 and the app's signature, quits a running
# Awake, puts the new one in /Applications and opens it. Nothing is installed if a check fails.
# AWAKE_VERSION=1.0.0 installs that version instead of the latest.
set -euo pipefail

REPO="arthur-bump-pm/awake-mac"
APP="/Applications/Awake.app"
WORK=""
trap 'if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

say() { printf '%s\n' "$*"; }
fail() {
    printf 'Awake install: %s\n' "$*" >&2
    exit 1
}

# Everything runs from here, so a download cut short partway through this script runs nothing.
main() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "Awake runs on macOS only."
    local macos major
    macos=$(sw_vers -productVersion)
    major=${macos%%.*}
    ((major >= 14)) || fail "Awake needs macOS 14 Sonoma or later; this Mac has $macos."

    local tag
    if [[ -n "${AWAKE_VERSION:-}" ]]; then
        tag="v${AWAKE_VERSION#v}"
    else
        # /releases/latest redirects to /releases/tag/<tag>; no API token needed.
        tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
        tag=${tag##*/}
    fi
    [[ "$tag" == v* ]] || fail "couldn't find the latest release on github.com/$REPO."
    local version=${tag#v}
    local zip="Awake-$version.zip"
    local base="https://github.com/$REPO/releases/download/$tag"

    WORK=$(mktemp -d)
    local tmp=$WORK

    say "Downloading Awake ${version}..."
    curl -fsSL "$base/$zip" -o "$tmp/$zip" || fail "couldn't download $base/$zip."
    curl -fsSL "$base/$zip.sha256" -o "$tmp/$zip.sha256" || fail "couldn't download the checksum."
    (cd "$tmp" && shasum -a 256 -c "$zip.sha256" >/dev/null 2>&1) ||
        fail "the download doesn't match its checksum, so nothing was installed."
    ditto -x -k "$tmp/$zip" "$tmp/unzipped"
    [[ -d "$tmp/unzipped/Awake.app" ]] || fail "the download has no Awake.app in it."
    codesign --verify --deep --strict "$tmp/unzipped/Awake.app" 2>/dev/null ||
        fail "the app's signature doesn't check out, so nothing was installed."

    # Quitting puts back whatever the running copy changed (lid-closed mode, the firewall); the new one starts fresh.
    if pgrep -x Awake >/dev/null; then
        say "Quitting the running Awake..."
        osascript -e 'quit app "Awake"' >/dev/null 2>&1 || true
        for _ in $(seq 1 50); do
            pgrep -x Awake >/dev/null || break
            sleep 0.2
        done
        pgrep -x Awake >/dev/null && fail "Awake didn't quit. Quit it from its menu, then run this again."
    fi

    # sudo when /Applications isn't writable, or the copy there isn't yours (an earlier install with sudo).
    local sudo=""
    if [[ ! -w /Applications ]] || { [[ -e "$APP" ]] && [[ ! -O "$APP" ]]; }; then
        sudo="sudo"
        say "Installing into /Applications needs your password."
    fi
    # The new copy goes in next to the old one first, so a failure never leaves a half-deleted app.
    local staged="/Applications/.Awake-$version-$$.app"
    $sudo rm -rf "$staged"
    $sudo ditto "$tmp/unzipped/Awake.app" "$staged" || fail "couldn't copy Awake into /Applications."
    # curl doesn't flag downloads for Gatekeeper; clear the flag anyway in case something else did.
    $sudo xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
    if ! { $sudo rm -rf "$APP" && $sudo mv "$staged" "$APP"; }; then
        $sudo rm -rf "$staged"
        fail "couldn't replace $APP. Delete it by hand, then run this again."
    fi

    open "$APP"
    say "Awake ${version} is in /Applications and running: look for the eyes in your menu bar."
}

main "$@"
