#!/bin/bash
set -euo pipefail

# ContinuityHelper.app — vlastní bundle ID + vlastní App Sandbox (ne inherit).
# Keo ho spouští přes NSWorkspace; sdílená data přes App Group.
# Nutné pro Mac App Store / TestFlight.

HELPER_SRC="${SRCROOT}/ContinuityHelper/main.swift"
HELPER_PLIST="${SRCROOT}/ContinuityHelper/Info.plist"
HELPER_ENTS="${SRCROOT}/Mac/ContinuityHelper.entitlements"
HELPER_APP="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/ContinuityHelper.app"
HELPER_BIN="${HELPER_APP}/Contents/MacOS/ContinuityHelper"
HELPER_TMP="${DERIVED_FILE_DIR:-${TEMP_DIR:-/tmp}}/ContinuityHelper"
SWIFTC="${SWIFT_EXEC:-$(xcrun --find swiftc)}"

mkdir -p "$(dirname "$HELPER_BIN")" "$(dirname "$HELPER_TMP")"
"$SWIFTC" -O -o "$HELPER_TMP" "$HELPER_SRC" -framework AppKit -framework CoreGraphics
rm -rf "${HELPER_TMP}.dSYM"
chmod u+w "$HELPER_TMP"

cp -f "$HELPER_TMP" "$HELPER_BIN"
chmod u+w "$HELPER_BIN"
cp -f "$HELPER_PLIST" "${HELPER_APP}/Contents/Info.plist"
rm -rf "${HELPER_APP}/Contents/_CodeSignature" "${HELPER_BIN}.dSYM"

# Odstraň starý bare binary v MacOS/
rm -f "${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/MacOS/ContinuityHelper"

SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] || [ "${EXPANDED_CODE_SIGN_IDENTITY}" = "-" ]; then
  SIGN_ID="-"
fi

# Vlastní sandbox + App Group (NE inherit). Bez application-identifier —
# ten vyžaduje App ID cz.samekt.keo.continuityhelper v developer portálu;
# Xcode Archive ho doplní při distribuci, pokud App ID existuje.
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
  --entitlements "$HELPER_ENTS" "$HELPER_BIN" || \
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$HELPER_ENTS" "$HELPER_BIN"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
  --entitlements "$HELPER_ENTS" "$HELPER_APP" 2>/dev/null || \
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$HELPER_ENTS" "$HELPER_APP"

if ! codesign -d --entitlements :- "$HELPER_BIN" 2>/dev/null | grep -q 'app-sandbox'; then
  echo "error: ContinuityHelper must be sandboxed for TestFlight / Mac App Store" >&2
  exit 1
fi

if codesign -d --entitlements :- "$HELPER_BIN" 2>/dev/null | grep -q 'com.apple.security.inherit'; then
  echo "error: ContinuityHelper must not use sandbox inherit" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${HELPER_APP}/Contents/Info.plist" | grep -q 'continuityhelper' \
  || { echo "error: ContinuityHelper.app must have distinct bundle id" >&2; exit 1; }

echo "Embedded ContinuityHelper.app (sandboxed + App Group) → $HELPER_APP"
