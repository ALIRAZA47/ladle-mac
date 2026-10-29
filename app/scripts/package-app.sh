#!/bin/bash
# Builds Ladle for Apple silicon and Intel and packages it the way releases ship it:
# Ladle.app signed inside-out, Ladle.dmg with an Applications link, Ladle-Chrome-Extension.zip,
# and, given a Sparkle key, the update's EdDSA signature in sparkle.json. The release workflow and
# App CI's packaging dry run both run this script, so a tag should rarely fail on packaging.
#
#   LADLE_VERSION=0.1.0 LADLE_BUILD=1 LADLE_SPARKLE_KEY_FILE=key.txt app/scripts/package-app.sh
#
# Environment:
#   LADLE_VERSION, LADLE_BUILD    required: CFBundleShortVersionString and CFBundleVersion
#   LADLE_OUT                     where the results go (default: app/build/package)
#   LADLE_SIGN_IDENTITY           "-" (default) signs ad hoc. A "Developer ID Application: …"
#                                 identity also turns on the hardened runtime and a secure timestamp.
#   LADLE_KEYCHAIN                the keychain holding that identity
#   LADLE_NOTARIZE=1              Developer ID only: notarize and staple the app and the DMG
#                                 (needs ASC_KEY_PATH, ASC_API_KEY_ID and ASC_API_ISSUER_ID)
#   LADLE_SPARKLE_KEY_FILE        Sparkle's private EdDSA key: signs Ladle.dmg for Sparkle and
#                                 writes sparkle.json
#   LADLE_PUBLIC_ED_KEY_OVERRIDE  CI's dry run only: puts this SUPublicEDKey in the app before
#                                 signing, to match a throwaway key. Releases use Info.plist's key.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
: "${LADLE_VERSION:?Set LADLE_VERSION, like 0.1.0}"
: "${LADLE_BUILD:?Set LADLE_BUILD, like 1}"
out="${LADLE_OUT:-$app_dir/build/package}"
identity="${LADLE_SIGN_IDENTITY:--}"
work="$out/work"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$work"

step "Generating the Xcode project"
(cd "$app_dir" && xcodegen generate --quiet)

# Built ad hoc with the hardened runtime off: everything is re-signed below. With an ad-hoc
# signature, the hardened runtime's library validation would refuse to load Sparkle.framework.
step "Building Ladle $LADLE_VERSION ($LADLE_BUILD) for Apple silicon and Intel"
xcodebuild build -quiet \
  -project "$app_dir/Ladle.xcodeproj" \
  -scheme Ladle \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$work/DerivedData" \
  -clonedSourcePackagesDirPath "$work/SourcePackages" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$LADLE_VERSION" \
  CURRENT_PROJECT_VERSION="$LADLE_BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO

app="$out/Ladle.app"
ditto "$work/DerivedData/Build/Products/Release/Ladle.app" "$app"

plist="$app/Contents/Info.plist"
if [ -n "${LADLE_PUBLIC_ED_KEY_OVERRIDE:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $LADLE_PUBLIC_ED_KEY_OVERRIDE" "$plist"
fi
case "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" in
  "" | REPLACE_WITH*) fail "SUPublicEDKey in app/Ladle/Info.plist is still the placeholder; Ladle could never take an update. See app/RELEASING.md." ;;
esac

step "Signing ($([ "$identity" = - ] && echo "ad hoc" || echo "$identity")), inside out"
flags=(--force --sign "$identity")
if [ "$identity" != - ]; then
  flags+=(--options runtime --timestamp)
  if [ -n "${LADLE_KEYCHAIN:-}" ]; then flags+=(--keychain "$LADLE_KEYCHAIN"); fi
fi

# Signs one piece of code, keeping the entitlements it was built with.
sign() {
  local entitlements="$work/entitlements.plist"
  if codesign -d --entitlements - --xml "$1" > "$entitlements" 2> /dev/null && [ -s "$entitlements" ]; then
    codesign "${flags[@]}" --entitlements "$entitlements" --generate-entitlement-der "$1"
  else
    codesign "${flags[@]}" "$1"
  fi
}

sparkle="$app/Contents/Frameworks/Sparkle.framework"
[ -d "$sparkle" ] || fail "Ladle.app has no Sparkle.framework"
sparkle_version="$sparkle/Versions/$(readlink "$sparkle/Versions/Current")"
for helper in "$sparkle_version"/XPCServices/*.xpc "$sparkle_version/Autoupdate" "$sparkle_version/Updater.app"; do
  if [ -e "$helper" ]; then sign "$helper"; fi
done
sign "$sparkle"
for other in "$app"/Contents/Frameworks/*; do
  if [ "$other" != "$sparkle" ] && [ -e "$other" ]; then sign "$other"; fi
done
sign "$app/Contents/MacOS/LadleBridge"
sign "$app/Contents/PlugIns/SafariExtension.appex"
sign "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if [ "${LADLE_NOTARIZE:-0}" = 1 ]; then
  [ "$identity" != - ] || fail "Notarizing needs a Developer ID identity"
  step "Notarizing Ladle.app"
  ditto -c -k --keepParent "$app" "$work/Ladle.zip"
  "$here/notarize.sh" "$work/Ladle.zip"
  xcrun stapler staple "$app"
fi

step "Making Ladle.dmg"
dmg="$out/Ladle.dmg"
mkdir -p "$work/dmg"
ditto "$app" "$work/dmg/Ladle.app"
ln -s /Applications "$work/dmg/Applications"
# hdiutil sometimes finds the volume busy on hosted runners; try again.
for attempt in 1 2 3; do
  if hdiutil create -volname Ladle -srcfolder "$work/dmg" -fs HFS+ -format UDZO -ov "$dmg"; then break; fi
  [ "$attempt" != 3 ] || fail "hdiutil couldn't make Ladle.dmg"
  sleep 10
done
if [ "$identity" != - ]; then
  dmg_flags=(--force --sign "$identity" --timestamp)
  if [ -n "${LADLE_KEYCHAIN:-}" ]; then dmg_flags+=(--keychain "$LADLE_KEYCHAIN"); fi
  codesign "${dmg_flags[@]}" "$dmg"
  if [ "${LADLE_NOTARIZE:-0}" = 1 ]; then
    step "Notarizing Ladle.dmg"
    "$here/notarize.sh" "$dmg"
    xcrun stapler staple "$dmg"
  fi
fi

step "Packaging the Chrome extension"
node "$app_dir/BrowserExtension/build.mjs" --release
cp "$app_dir/BrowserExtension/dist/Ladle-Chrome-Extension.zip" "$out/Ladle-Chrome-Extension.zip"

if [ -n "${LADLE_SPARKLE_KEY_FILE:-}" ]; then
  step "Signing Ladle.dmg for Sparkle"
  # Sparkle's tools come with its Swift package, in bin/ next to the framework. (bin/old_dsa_scripts
  # has another sign_update, for the old DSA keys.)
  sign_update="$(find "$work/SourcePackages/artifacts" -type f -path '*/bin/sign_update' | head -n 1)"
  [ -n "$sign_update" ] || fail "Sparkle's sign_update isn't in the resolved packages"
  [ -x "$sign_update" ] || chmod u+x "$sign_update"
  attributes="$("$sign_update" --ed-key-file "$LADLE_SPARKLE_KEY_FILE" "$dmg")"
  python3 "$here/publish_release.py" sparkle-json \
    --version "$LADLE_VERSION" --build "$LADLE_BUILD" --attributes "$attributes" --out "$out/sparkle.json"
  signature="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["edSignature"])' "$out/sparkle.json")"
  "$sign_update" --verify --ed-key-file "$LADLE_SPARKLE_KEY_FILE" "$dmg" "$signature"
fi

step "Done"
ls -l "$out"
