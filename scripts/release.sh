#!/bin/zsh
# Builds OpenAccs for distribution: Developer ID signature, Apple notarization, stapled ticket, zip.
#
#   scripts/release.sh            → build/OpenAccs-<version>.zip and docs/appcast.xml
#   NOTES=notes.md scripts/release.sh   the same, with these release notes in the update window
#
# Needs a "Developer ID Application" certificate in the keychain (TEAM_ID selects the team) and an
# App Store Connect API key for notarytool in ~/.appstoreconnect/config.json (key_filepath, key_id,
# issuer_id). Set NOTARIZE=0 to skip notarization.
set -euo pipefail
cd "${0:A:h}/.."
team=${TEAM_ID:-R4A779QVVY}
out=build/release
rm -rf "$out" && mkdir -p "$out"

xcodegen generate >/dev/null
xcodebuild -project OpenAccs.xcodeproj -scheme OpenAccs -configuration Release -derivedDataPath "$out/dd" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build | grep -E "error:|BUILD" || true
app="$out/dd/Build/Products/Release/OpenAccs.app"
[[ -d $app ]] || { echo "build failed"; exit 1 }
# Sparkle's helpers come signed by their authors: sign them with ours, inside out, then the app again.
identity=$(security find-identity -v -p codesigning | awk -v t="($team)" '/Developer ID Application/ && index($0, t) { print $2; exit }')
[[ -n $identity ]] || { echo "no Developer ID Application identity for team $team"; exit 1 }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
resign() { codesign --force --timestamp --options runtime --sign "$identity" "$@" }
resign "$sparkle/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
resign "$sparkle/Versions/B/Autoupdate"
resign "$sparkle/Versions/B/Updater.app"
resign "$sparkle"
resign "$app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
zip="build/OpenAccs-$version.zip"

if [[ ${NOTARIZE:-1} == 1 ]]; then
  config=~/.appstoreconnect/config.json
  key=$(plutil -extract key_filepath raw -o - $config); key=${key/#\~/$HOME}
  key_id=$(plutil -extract key_id raw -o - $config)
  issuer=$(plutil -extract issuer_id raw -o - $config)
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --key "$key" --key-id "$key_id" --issuer "$issuer" --wait
  xcrun stapler staple "$app"
  spctl -a -vv -t exec "$app"
fi

rm -f "$zip" && ditto -c -k --keepParent "$app" "$zip"

# The update feed, docs/appcast.xml (GitHub Pages), signed with the key from 1Password.
key=${SPARKLE_KEY:-$HOME/.openaccs/sparkle-key}
if [[ ! -f $key ]]; then
  mkdir -p "${key:h}" && op read --out-file "$key" --file-mode 0600 "op://Development/OpenAccs Sparkle EdDSA private key/password"
fi
bin="$out/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"
feed="$out/feed"
rm -rf "$feed" && mkdir -p "$feed"
[[ -f docs/appcast.xml ]] && cp docs/appcast.xml "$feed/"
cp "$zip" "$feed/"
[[ -n ${NOTES:-} ]] && cp "$NOTES" "$feed/OpenAccs-$version.md"
"$bin/generate_appcast" --ed-key-file "$key" --embed-release-notes --maximum-deltas 0 \
  --download-url-prefix "https://github.com/mikwiseman/openaccs/releases/download/v$version/" \
  --link https://github.com/mikwiseman/openaccs -o "$feed/appcast.xml" "$feed"
"$bin/sign_update" --ed-key-file "$key" "$feed/appcast.xml"
"$bin/sign_update" --verify --ed-key-file "$key" "$feed/appcast.xml"
mkdir -p docs && cp "$feed/appcast.xml" docs/appcast.xml

shasum -a 256 "$zip"
echo "$zip"
