#!/bin/bash
# Checks what package-app.sh made, the way people get it: mounts Ladle.dmg and looks inside.
# The release workflow runs it before publishing, App CI after its packaging dry run.
#
#   LADLE_VERSION=0.1.0 LADLE_BUILD=1 app/scripts/verify-package.sh
#
# Environment: LADLE_VERSION, LADLE_BUILD and LADLE_OUT as for package-app.sh, and
# LADLE_SIGN_IDENTITY when the app should carry a Developer ID signature rather than an ad-hoc one.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
: "${LADLE_VERSION:?Set LADLE_VERSION}"
: "${LADLE_BUILD:?Set LADLE_BUILD}"
out="${LADLE_OUT:-$app_dir/build/package}"
identity="${LADLE_SIGN_IDENTITY:--}"
dmg="$out/Ladle.dmg"
extension_zip="$out/Ladle-Chrome-Extension.zip"

fail() { echo "error: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

[ -f "$dmg" ] || fail "no $dmg"
[ -f "$extension_zip" ] || fail "no $extension_zip"

mount="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" > /dev/null
trap 'hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet || true' EXIT
app="$mount/Ladle.app"
[ -d "$app" ] || fail "Ladle.dmg has no Ladle.app"
[ "$(readlink "$mount/Applications")" = /Applications ] || fail "Ladle.dmg has no Applications link"
ok "Ladle.dmg holds Ladle.app and an Applications link"

# Code signatures, nested code first.
contents="$app/Contents"
sparkle="$contents/Frameworks/Sparkle.framework"
[ -d "$sparkle" ] || fail "no Sparkle.framework"
[ -x "$contents/MacOS/LadleBridge" ] || fail "no LadleBridge"
[ -d "$contents/PlugIns/SafariExtension.appex" ] || fail "no Safari extension"
for code in "$sparkle"/Versions/Current/XPCServices/*.xpc "$sparkle/Versions/Current/Autoupdate" \
  "$sparkle/Versions/Current/Updater.app" "$sparkle" "$contents/MacOS/LadleBridge" \
  "$contents/PlugIns/SafariExtension.appex"; do
  if [ -e "$code" ]; then codesign --verify --strict "$code" || fail "bad signature: ${code#"$mount/"}"; fi
done
codesign --verify --deep --strict --verbose=2 "$app"
details="$(codesign -dv "$app" 2>&1)"
if [ "$identity" = - ]; then
  grep -q "Signature=adhoc" <<< "$details" || fail "Ladle.app isn't ad-hoc signed: $details"
  if grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<< "$details"; then fail "the hardened runtime is on; with ad-hoc signatures it can't load Sparkle"; fi
  ok "Ladle.app and everything in it are ad-hoc signed, hardened runtime off"
else
  grep -q "Authority=Developer ID Application" <<< "$details" || fail "Ladle.app isn't signed with Developer ID: $details"
  grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<< "$details" || fail "the hardened runtime is off"
  xcrun stapler validate "$app"
  ok "Ladle.app is signed with Developer ID, with the hardened runtime, and notarized"
fi
codesign -d --entitlements - --xml "$contents/PlugIns/SafariExtension.appex" 2> /dev/null | grep -q "com.apple.security.app-sandbox" \
  || fail "the Safari extension lost its entitlements"
ok "the Safari extension kept its sandbox entitlements"

# Info.plist and architectures.
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$contents/Info.plist"; }
[ "$(value CFBundleIdentifier)" = me.alirazakhan.Ladle ] || fail "bundle ID is $(value CFBundleIdentifier)"
[ "$(value CFBundleShortVersionString)" = "$LADLE_VERSION" ] || fail "version is $(value CFBundleShortVersionString), not $LADLE_VERSION"
[ "$(value CFBundleVersion)" = "$LADLE_BUILD" ] || fail "build is $(value CFBundleVersion), not $LADLE_BUILD"
[ "$(value SUFeedURL)" = https://ladle.alirazakhan.me/appcast.xml ] || fail "SUFeedURL is $(value SUFeedURL)"
public_key="$(value SUPublicEDKey)"
ok "Info.plist: me.alirazakhan.Ladle $LADLE_VERSION ($LADLE_BUILD), feed and EdDSA key set"
for binary in "$contents/MacOS/Ladle" "$contents/MacOS/LadleBridge"; do
  archs="$(lipo -archs "$binary")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "${binary##*/} is only $archs"
done
ok "Ladle and LadleBridge run on Apple silicon and Intel"
echo "Sparkle $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$sparkle/Resources/Info.plist") is embedded"

# LadleBridge answers a browser's hello, without Ladle running.
reply="$(python3 -c 'import struct, sys; m = b"{\"type\":\"hello\",\"id\":1}"; sys.stdout.buffer.write(struct.pack("<I", len(m)) + m)' \
  | perl -e 'alarm 20; exec @ARGV' "$contents/MacOS/LadleBridge" | tail -c +5)"
grep -q '"ok":true' <<< "$reply" || fail "LadleBridge didn't answer hello: $reply"
ok "LadleBridge answers native messages: $reply"

# The Chrome extension, ready for Load unpacked, with the ID Ladle allows.
manifest="$(unzip -p "$extension_zip" Ladle-Chrome-Extension/manifest.json)" || fail "the zip has no Ladle-Chrome-Extension/manifest.json"
extension_id="$(python3 -c '
import base64, hashlib, json, sys
key = json.loads(sys.stdin.read())["key"]
digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
print("".join(chr(ord("a") + int(c, 16)) for c in digest))' <<< "$manifest")"
grep -q "\"$extension_id\"" "$app_dir/Ladle/Browser/BrowserIntegration.swift" || fail "extension ID $extension_id isn't one LadleBridge allows"
if unzip -Z1 "$extension_zip" | grep -v '^Ladle-Chrome-Extension/' | grep -q .; then fail "files outside Ladle-Chrome-Extension/ in the zip"; fi
ok "Ladle-Chrome-Extension.zip unpacks to one folder; extension ID $extension_id"

# The update's EdDSA signature, checked against the key in the app people will run.
if [ -f "$out/sparkle.json" ]; then
  read -r version build signature length < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["version"], d["build"], d["edSignature"], d["length"])' "$out/sparkle.json")
  [ "$version" = "$LADLE_VERSION" ] && [ "$build" = "$LADLE_BUILD" ] || fail "sparkle.json is for $version ($build)"
  [ "$length" = "$(stat -f %z "$dmg")" ] || fail "sparkle.json says $length bytes; Ladle.dmg is $(stat -f %z "$dmg")"
  python3 "$here/sparkle_ed.py" verify "$dmg" "$signature" "$public_key"
  ok "sparkle.json matches Ladle.dmg, and its signature verifies with the app's SUPublicEDKey"
fi

# Gatekeeper rejects ad-hoc signed apps that aren't notarized; people approve the first launch.
if spctl --assess --type execute --verbose=2 "$app" 2>&1; then
  ok "Gatekeeper accepts Ladle.app"
else
  echo "note: Gatekeeper rejects Ladle.app, as expected without notarization (see the first-launch docs)"
fi
