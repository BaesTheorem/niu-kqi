#!/usr/bin/env bash
# Build KQi Rides. Default is an unsigned compile check; --device signs for a
# real iPhone. Regenerates the project first, because project.yml is the source
# of truth and anything set in Xcode's GUI is wiped on regenerate.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

# Resources that are copies of something else, fetched here rather than
# committed, so the repo does not carry a duplicate field table or 8 MB of font.
cp ../data/fields.json KQiRides/Resources/fields.json
FONT=KQiRides/Resources/MaterialSymbolsSharp.ttf
if [[ ! -f $FONT ]]; then
  LOCAL=~/Documents/material-design/fonts/MaterialSymbolsSharp.ttf
  if [[ -f $LOCAL ]]; then
    cp "$LOCAL" "$FONT"
  else
    curl -fsSL -o "$FONT" \
      https://raw.githubusercontent.com/google/material-design-icons/master/variablefont/MaterialSymbolsSharp%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf
  fi
fi

xcodegen generate

if [[ "${1:-}" == "--device" ]]; then
  # Delete the cached profile and the built app first: Xcode will happily reuse
  # a still-valid profile and skip codesign entirely, which silently re-ships an
  # expiring signature instead of restarting the 7-day clock.
  rm -rf build/dd/Build/Products/Debug-iphoneos/KQiRides.app
  exec xcodebuild -project KQiRides.xcodeproj -scheme KQiRides \
    -destination 'generic/platform=iOS' -derivedDataPath build/dd \
    -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic build
fi

exec xcodebuild -project KQiRides.xcodeproj -scheme KQiRides \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO build
