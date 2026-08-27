#!/bin/bash
# Package kernel for veux using AnyKernel3 (nebula pattern)
# Usage: ./package_kernel.sh
set -euo pipefail

KERNEL_DIR="$(pwd)"
OUT="$KERNEL_DIR/out"
AK3="$KERNEL_DIR/AnyKernel3"
BOOT_DIR="$OUT/arch/arm64/boot"

IMAGE="$BOOT_DIR/Image"
DTB="$BOOT_DIR/dts/vendor/xiaomi/veux.dtb"

# Verify build outputs exist
if [ ! -f "$IMAGE" ]; then
    echo "[ERROR] Image not found at $IMAGE"
    echo "Build kernel first: make -j$(nproc)"
    exit 1
fi

if [ ! -f "$DTB" ]; then
    echo "[ERROR] DTB not found at $DTB"
    echo "Build kernel first: make -j$(nproc)"
    exit 1
fi

echo "─────────────────────────────────────────────────"
echo "  Packaging kernel for veux (nebula pattern)"
echo "─────────────────────────────────────────────────"

# Step 1: Copy build outputs into AnyKernel3 staging area
cp "$IMAGE" "$AK3/"
cp "$DTB" "$AK3/dtb"

# Verify cmdline exists in AnyKernel3
if [ ! -f "$AK3/cmdline" ]; then
    echo "[ERROR] cmdline missing in AnyKernel3/"
    echo "Expected: AnyKernel3/cmdline"
    exit 1
fi

# Step 2: Create flashable zip (exclude git, tools binaries not needed)
cd "$AK3"
ZIP_NAME="XXKSU-veux-$(date +%Y%m%d-%H%M%S).zip"
zip -r9 "$KERNEL_DIR/$ZIP_NAME" . \
    -x '*.git*' 'README.md' 'LICENSE' '.github/*' \
    'Image.gz-dtb' 'tools/magiskboot' 'tools/busybox'
cd "$KERNEL_DIR"

# Step 3: Cleanup staging
rm -f "$AK3/Image" "$AK3/dtb"

echo ""
echo "─────────────────────────────────────────────────"
echo "[SUCCESS] Flashable zip created!"
echo "  File: $KERNEL_DIR/$ZIP_NAME"
echo "  Size: $(du -h "$KERNEL_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "  Contents: Image + dtb + cmdline + ak3-custom.sh"
echo ""
echo "  Flash:"
echo "    1. Transfer zip to phone"
echo "    2. Flash via Kernel Manager app (Franco, EXKM, etc.)"
echo "    3. OR flash via custom recovery (TWRP/OrangeFox)"
echo "─────────────────────────────────────────────────"
