#!/bin/zsh
# Builds OpenAccs for distribution: Developer ID signature, Apple notarization, stapled ticket, zip.
#
#   scripts/release.sh            → build/OpenAccs-<version>.zip
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
shasum -a 256 "$zip"
echo "$zip"
