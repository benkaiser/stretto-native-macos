#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your existing notarytool Keychain profile}"
app="$PWD/build/Stretto.app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" build/Stretto-notarization.zip
xcrun notarytool submit build/Stretto-notarization.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
ditto -c -k --keepParent "$app" build/Stretto-macos.zip
