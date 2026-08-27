#!/bin/bash
# veux kernel build script (Redmi Note 11 Pro 5G)
# Kernel 5.4.302 · QGKI · ksun · Clang/LLVM · ThinLTO
set -euo pipefail

# ── Toolchain ────────────────────────────────────────────────
export PATH="$HOME/Clang/LLVM-22.1.2-Linux-X64/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/Clang/LLVM-22.1.2-Linux-X64/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ── Build variables ──────────────────────────────────────────
ARCH=arm64
KERNEL=veux
OUT=out
DEFCONFIG=${KERNEL}_defconfig
JOBS=$(nproc --all)

# ── Clean mode ──────────────────────────────────────────────
if [ "${1:-}" = "clean" ]; then
    echo "[+] Cleaning old build artifacts..."
    rm -rf "$OUT"
    echo "[+] Cleaned. .config will be regenerated."
fi

# ── Sanity checks ────────────────────────────────────────────
if ! command -v clang &>/dev/null; then
    echo "[ERROR] clang not found in PATH"
    exit 1
fi

CLANG_VER=$(clang --version | head -1)
echo "─────────────────────────────────────────────────"
echo "  Kernel  : Linux 5.4.302 ($KERNEL)"
echo "  Clang   : $CLANG_VER"
echo "  LTO     : ThinLTO"
echo "  Threads : $JOBS"
echo "  Output  : $OUT/"
echo "─────────────────────────────────────────────────"

# ── Step 1: Generate .config (if not present) ────────────────
if [ ! -f "$OUT/.config" ]; then
    echo "[+] Generating .config from $DEFCONFIG ..."
    make ARCH=$ARCH O=$OUT LLVM=1 LLVM_IAS=1 $DEFCONFIG
    echo "[+] .config generated."
else
    echo "[*] $OUT/.config already exists, will reuse."
    echo "    To regenerate: ./build_kernel.sh clean"
fi

# ── Step 2: Build ────────────────────────────────────────────
echo "[+] Building kernel with -j$JOBS ..."
make -j$JOBS \
    ARCH=$ARCH \
    O=$OUT \
    LLVM=1 \
    LLVM_IAS=1 \
    2>&1 | tee build.log

BUILD_EXIT=${PIPESTATUS[0]}

# ── Step 3: Result ───────────────────────────────────────────
if [ $BUILD_EXIT -ne 0 ]; then
    echo ""
    echo "[FAILED] Build failed with exit code $BUILD_EXIT"
    echo "[*] Check build.log for errors"
    # Show last 30 lines of errors
    echo "── last errors ──"
    tail -30 build.log | grep -i "error" || true
    exit $BUILD_EXIT
fi

# ── Locate output ────────────────────────────────────────────
# veux uses CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL=y → raw Image, not Image.gz
KERNEL_IMAGE="$OUT/arch/$ARCH/boot/Image"
if [ -f "$KERNEL_IMAGE" ]; then
    echo ""
    echo "─────────────────────────────────────────────────"
    echo "[SUCCESS] Kernel built successfully!"
    echo "  Image : $KERNEL_IMAGE"
    echo "  Size  : $(du -h "$KERNEL_IMAGE" | cut -f1)"
    echo ""
    echo "  Next step: ./package_kernel.sh"
    echo "─────────────────────────────────────────────────"
else
    echo ""
    echo "[WARNING] Build completed but Image not found"
    echo "  Expected: $KERNEL_IMAGE"
    ls -la "$OUT/arch/$ARCH/boot/" 2>/dev/null || true
fi
