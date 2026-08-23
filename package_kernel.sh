#!/bin/bash
# Package kernel for veux using AnyKernel3 (stock format)
set -euo pipefail

KERNEL_DIR="$(pwd)"
OUT="$KERNEL_DIR/out"
AK3="$KERNEL_DIR/AnyKernel3"
BOOT_DIR="$OUT/arch/arm64/boot"

IMAGE="$BOOT_DIR/Image"
DTB="$BOOT_DIR/dts/vendor/xiaomi/veux.dtb"

if [ ! -f "$IMAGE" ]; then
    echo "[ERROR] $IMAGE not found. Build the kernel first."
    exit 1
fi

if [ ! -f "$DTB" ]; then
    echo "[ERROR] $DTB not found. Build the kernel first."
    exit 1
fi

echo "─────────────────────────────────────────────────"
echo "  Packaging kernel for veux (stock format)"
echo "─────────────────────────────────────────────────"

# Step 1: Copy raw Image + dtb (NOT gzipped, matching stock format)
cp "$IMAGE" "$AK3/"
cp "$DTB" "$AK3/dtb"   # stock names it just 'dtb', not 'veux.dtb'

# Step 2: Create flashable zip
cd "$AK3"
ZIP_NAME="XXKSU-veux-$(date +%Y%m%d).zip"
zip -r9 "$KERNEL_DIR/$ZIP_NAME" . \
    -x '*.git*' 'README.md' 'LICENSE' '.github/*' 'Image.gz-dtb'
cd "$KERNEL_DIR"

# Step 3: Cleanup
rm -f "$AK3/Image" "$AK3/Image.gz-dtb" "$AK3/dtb"

echo ""
echo "─────────────────────────────────────────────────"
echo "[SUCCESS] Flashable zip created!"
echo "  File: $KERNEL_DIR/$ZIP_NAME"
echo "  Size: $(du -h "$KERNEL_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "  Contents: Image (raw) + dtb (separate)"
echo "  Includes: ak3-custom.sh, fdtput, bspatch, cmdline"
echo ""
echo "  To flash:"
echo "    1. Transfer zip to phone"
echo "    2. Flash via Kernel Manager app (Franco, EXKM, etc.)"
echo "    3. OR flash via custom recovery (TWRP/OrangeFox)"
echo "─────────────────────────────────────────────────"
