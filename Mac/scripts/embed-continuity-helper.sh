#!/bin/bash
set -euo pipefail
HELPER_SRC="${SRCROOT}/ContinuityHelper/main.swift"
HELPER_OUT="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/MacOS/ContinuityHelper"
HELPER_ENTITLEMENTS="${SRCROOT}/Mac/ContinuityHelper.entitlements"
mkdir -p "$(dirname "$HELPER_OUT")"
swiftc -O -o "$HELPER_OUT" "$HELPER_SRC" -framework AppKit
# dSYM nesmí skončit uvnitř .app (ASC to odmítne kvůli com.apple.xcode.dsym.*)
rm -rf "${HELPER_OUT}.dSYM" "$(dirname "$HELPER_OUT")/ContinuityHelper.dSYM"

# App Store vyžaduje sandbox entitlement i u pomocného executablu v MacOS/
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
    --options runtime \
    --entitlements "$HELPER_ENTITLEMENTS" \
    --timestamp=none \
    "$HELPER_OUT"
else
  codesign --force --sign - \
    --options runtime \
    --entitlements "$HELPER_ENTITLEMENTS" \
    "$HELPER_OUT"
fi

# Ověř sandbox
codesign -d --entitlements :- "$HELPER_OUT" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' \
  || { echo "error: ContinuityHelper missing app-sandbox entitlement" >&2; exit 1; }

echo "Embedded ContinuityHelper → $HELPER_OUT"
