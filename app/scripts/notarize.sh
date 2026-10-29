#!/bin/bash
# Notarizes a zip or disk image with an App Store Connect API key and waits for the answer.
#
#   ASC_KEY_PATH=AuthKey.p8 ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… notarize.sh Ladle.dmg
#
# On anything but "Accepted" it prints Apple's log and fails.
set -euo pipefail

file="$1"
auth=(--key "$ASC_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")

result=$(xcrun notarytool submit "$file" "${auth[@]}" --wait --timeout 1h --output-format json)
echo "$result"
field() { python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$result" "$1"; }
status=$(field status)
id=$(field id)

if [ "$status" != "Accepted" ]; then
  echo "::error::Notarization of $(basename "$file") ended with status \"$status\"."
  if [ -n "$id" ]; then xcrun notarytool log "$id" "${auth[@]}" || true; fi
  exit 1
fi
