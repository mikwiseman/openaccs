#!/bin/sh
# Installs OpenAccs on this Mac:
#
#   curl -fsSL https://mikwiseman.github.io/openaccs/install.sh | sh
#
# Takes the newest release from the signed update feed, checks that Apple notarized it and that it is
# signed by its developer (team R4A779QVVY), moves it to /Applications and opens it. No sudo. From then on
# OpenAccs updates itself. OPENACCS_DIR installs somewhere else (for testing).
set -eu

dir=${OPENACCS_DIR:-/Applications}
app="$dir/OpenAccs.app"
team=R4A779QVVY
feed=https://mikwiseman.github.io/openaccs/appcast.xml

fail() { echo "OpenAccs: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "OpenAccs is a Mac app. For a server, run 'openaccs vps user@host' on your Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."
if [ -d "$app" ]; then
  echo "OpenAccs is already installed in $dir. It updates itself."
  open "$app"
  exit 0
fi

url=$(curl -fsSL "$feed" | sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' | head -n 1)
case "$url" in
  https://github.com/mikwiseman/openaccs/releases/download/*) ;;
  *) fail "couldn't read the newest release from $feed." ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $(basename "$url")…"
curl -fsSL -o "$tmp/OpenAccs.zip" "$url"
ditto -x -k "$tmp/OpenAccs.zip" "$tmp/unzipped"
new="$tmp/unzipped/OpenAccs.app"
[ -d "$new" ] || fail "the download has no OpenAccs.app."

codesign --verify --deep --strict "$new" 2>/dev/null || fail "the app's signature doesn't check out. Nothing was installed."
signer=$(codesign -dv "$new" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$signer" = "$team" ] || fail "the app is signed by '$signer', not by OpenAccs's developer. Nothing was installed."
spctl -a -t exec "$new" 2>/dev/null || fail "Gatekeeper doesn't accept the app. Nothing was installed."

mkdir -p "$dir"
ditto "$new" "$app" || fail "couldn't write to $dir. Try: OPENACCS_DIR=~/Applications sh"
echo "Installed $app. Opening it: look for its icon in the menu bar."
open "$app"
