#!/bin/bash
set -euo pipefail
HELPER_SRC="${SRCROOT}/ContinuityHelper/main.swift"
HELPER_OUT="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/MacOS/ContinuityHelper"
mkdir -p "$(dirname "$HELPER_OUT")"
swiftc -O -o "$HELPER_OUT" "$HELPER_SRC" -framework AppKit
# Podepiš stejným identity jako app (sandbox inherit při Process)
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --entitlements "${SRCROOT}/Mac/KeoMac.entitlements" "$HELPER_OUT" || \
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "$HELPER_OUT" || true
else
  codesign --force --sign - --entitlements "${SRCROOT}/Mac/KeoMac.entitlements" "$HELPER_OUT" || \
  codesign --force --sign - "$HELPER_OUT" || true
fi
echo "Embedded ContinuityHelper → $HELPER_OUT"
