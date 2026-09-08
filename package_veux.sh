#!/bin/bash
# ============================================================================
# package_veux.sh – Repackage freshly built kernel into an AnyKernel3 zip
# ============================================================================
# Layout source: nebula-veux/ (known-good on veux/peux, PixelOS)
#   - boot   : Image            -> flash_boot
#   - vendor_boot: dtb + cmdline-> split/flash + custom cmdline
#   - dtbo   : erased           -> erase_dtbo (custom)
#   - device check: veux / peux
#
# Usage:
#   ./package_veux.sh [output.zip]
# ============================================================================
set -euo pipefail

# --- 0. Sanity checks --------------------------------------------------------
for f in arch/arm64/boot/Image \
         arch/arm64/boot/dts/vendor/xiaomi/veux.dtb \
         nebula-veux/anykernel.sh \
         nebula-veux/tools/ak3-core.sh \
         nebula-veux/tools/ak3-custom.sh \
         nebula-veux/META-INF/com/google/android/update-binary; do
    [ -f "$f" ] || { echo "ERROR: missing $f (build first / keep nebula-veux)"; exit 1; }
done

REL=$(sed -n 's/.*"\(.*\)".*/\1/p' include/generated/utsrelease.h | head -1)
OUT="${1:-veux-AnyKernel3-${REL//\//-}.zip}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# --- 1. Stage the known-good nebula payload ---------------------------------
cp -r nebula-veux/. "$STAGE/"
rm -f "$STAGE/Image" "$STAGE/dtb"

# --- 2. Swap in OUR kernel artifacts (same build, paired Image+dtb) ----------
cp arch/arm64/boot/Image "$STAGE/Image"
cp arch/arm64/boot/dts/vendor/xiaomi/veux.dtb "$STAGE/dtb"

# --- 3. Rebrand (keep do.devicecheck + veux/peux as-is) ----------------------
sed -i "s|^kernel.string=.*|kernel.string=positron kernel $REL|" "$STAGE/anykernel.sh"

# --- 4. Zip: AK3 requires payload files at the archive ROOT ------------------
echo "== Packaging $OUT (kernel: $REL)"
( cd "$STAGE" && zip -r9 "$OLDPWD/$OUT" . ) > /dev/null
ls -la "$OUT"
echo "== Done. Flash in recovery (boot + vendor_boot patched, dtbo erased)."
