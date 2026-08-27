#!/bin/bash
# Package kernel for veux — replicate nebula's exact zip structure
# Nebula zip contains ONLY these 12 files (no extra tools):
#   anykernel.sh, banner, cmdline, dtb, Image, LICENSE,
#   META-INF/com/google/android/update-binary,
#   META-INF/com/google/android/updater-script,
#   tools/ak3-core.sh, tools/ak3-custom.sh, tools/busybox,
#   tools/fdtput, tools/magiskboot
#
# Usage: ./package_kernel.sh
set -euo pipefail

KERNEL_DIR="$(pwd)"
OUT="$KERNEL_DIR/out"
AK3="$KERNEL_DIR/AnyKernel3"
STAGING="$KERNEL_DIR/.ak3-staging"
BOOT_DIR="$OUT/arch/arm64/boot"

IMAGE="$BOOT_DIR/Image"
DTB="$BOOT_DIR/dts/vendor/xiaomi/veux.dtb"

# Verify build outputs exist
if [ ! -f "$IMAGE" ]; then
    echo "[ERROR] Image not found at $IMAGE"
    echo "Build kernel first: make -j\$(nproc)"
    exit 1
fi

if [ ! -f "$DTB" ]; then
    echo "[ERROR] DTB not found at $DTB"
    echo "Build kernel first: make -j\$(nproc)"
    exit 1
fi

if [ ! -f "$AK3/cmdline" ]; then
    echo "[ERROR] cmdline missing in AnyKernel3/"
    exit 1
fi

echo "─────────────────────────────────────────────────"
echo "  Packaging kernel for veux (nebula structure)"
echo "─────────────────────────────────────────────────"

# Clean previous staging
rm -rf "$STAGING"
mkdir -p "$STAGING/META-INF/com/google/android"
mkdir -p "$STAGING/tools"

# Step 1: Copy root-level files (matching nebula exactly)
cp "$AK3/anykernel.sh" "$STAGING/"
cp "$AK3/banner" "$STAGING/" 2>/dev/null || true
cp "$AK3/cmdline" "$STAGING/"
cp "$AK3/LICENSE" "$STAGING/" 2>/dev/null || true
cp "$IMAGE" "$STAGING/"
cp "$DTB" "$STAGING/dtb"

# Step 2: Copy META-INF (keep existing update-binary/updater-script)
if [ -d "$AK3/META-INF" ]; then
    cp "$AK3/META-INF/com/google/android/update-binary" "$STAGING/META-INF/com/google/android/" 2>/dev/null || true
    cp "$AK3/META-INF/com/google/android/updater-script" "$STAGING/META-INF/com/google/android/" 2>/dev/null || true
fi

# Step 3: Copy ONLY the 3 tools that nebula ships (no bspatch, fec, httools, lptools, etc.)
cp "$AK3/tools/ak3-core.sh" "$STAGING/tools/"
cp "$AK3/tools/ak3-custom.sh" "$STAGING/tools/"
cp "$AK3/tools/busybox" "$STAGING/tools/" 2>/dev/null || true
cp "$AK3/tools/fdtput" "$STAGING/tools/" 2>/dev/null || true
cp "$AK3/tools/magiskboot" "$STAGING/tools/" 2>/dev/null || true

# Step 4: Create flashable zip (no compression on Image/dtb — they're already compressed)
cd "$STAGING"
ZIP_NAME="ksun-veux-$(date +%Y%m%d-%H%M%S).zip"
zip -r9 "$KERNEL_DIR/$ZIP_NAME" . 2>/dev/null
cd "$KERNEL_DIR"

# Step 5: Cleanup
rm -rf "$STAGING"

echo ""
echo "─────────────────────────────────────────────────"
echo "[SUCCESS] Flashable zip created!"
echo "  File: $KERNEL_DIR/$ZIP_NAME"
echo "  Size: $(du -h "$KERNEL_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "  Contents (nebula structure, 12 files):"
find "$STAGING" -type f 2>/dev/null | head -15 || true
echo ""
echo "  To flash:"
echo "    1. Transfer zip to phone"
echo "    2. Flash via Kernel Manager app (Franco, EXKM, etc.)"
echo "    3. OR flash via custom recovery (TWRP/OrangeFox)"
echo "─────────────────────────────────────────────────"
