#!/bin/bash
# ============================================================================
# build_veux.sh – Build veux kernel with all optimizations
# ============================================================================
# Toolchain: /home/hayyan/toolchains/clang-r596125/bin/
#
# Auto‑enabled optimizations:
#   - ThinLTO (always flips CONFIG_THINLTO=y)
#   - BOLT (if llvm-bolt found)
#   - MLGO (if ~/mlgo-model.mlgo exists)
#
# ReSukiSU requirements (CONFIG_KALLSYMS_ALL, CONFIG_DEBUG_KERNEL) are
# now permanently set in arch/arm64/configs/veux_defconfig.
#
# Usage:
#   ./build_veux.sh                     # normal build (always starts clean)
#   PROFILE_GEN=1 ./build_veux.sh       # instrumented build for PGO
#   PROFILE_USE=... ./build_veux.sh     # rebuild using profile
#
# NOTE: every run wipes the tree with `make mrproper` (removes .config and
# all build artifacts), then regenerates .config from veux_defconfig.
# Expect a full rebuild on every invocation.
# ============================================================================
set -euo pipefail

# --- 0. Always wipe previous build ------------------------------------------
# mrproper removes .config and all generated files/build artifacts so the
# build always starts from a pristine tree; .config is regenerated below
# from arch/arm64/configs/veux_defconfig.
echo "== Running make mrproper to start from a clean tree"
make mrproper

# --- 1. Toolchain -----------------------------------------------------------
export PATH="/home/hayyan/toolchains/clang-r596125/bin:$PATH"

# --- 2. Architecture & cross-compilation -------------------------------------
export ARCH=arm64
export CROSS_COMPILE="aarch64-linux-gnu-"
export LLVM=1
export LLVM_IAS=1
JOBS=$(nproc --all)

# --- 3. Optional environment variables (PGO only) ----------------------------
PROFILE_GEN="${PROFILE_GEN:-0}"
PROFILE_USE="${PROFILE_USE:-}"

# --- 4. Auto‑detect MLGO model ----------------------------------------------
MLGO_MODEL="${MLGO_MODEL:-}"
if [ -z "$MLGO_MODEL" ] && [ -f "$HOME/mlgo-model.mlgo" ]; then
    MLGO_MODEL="$HOME/mlgo-model.mlgo"
    echo "== MLGO model auto‑detected: $MLGO_MODEL"
fi

# --- 5. Auto‑detect BOLT ----------------------------------------------------
BOLT_ENABLE=0
if command -v llvm-bolt &>/dev/null; then
    BOLT_ENABLE=1
    echo "== BOLT auto‑enabled (llvm-bolt found)"
else
    echo "== BOLT not available (llvm-bolt not in PATH)"
fi

# --- 6. Base compiler flags (always safe) -----------------------------------
KCFLAGS="-O2 -fvisibility=hidden -mcpu=cortex-a76"
KCPPFLAGS="-O2"

EXTRA_CFLAGS="-fno-builtin-wcslen -fno-strict-overflow -fno-merge-all-constants"
EXTRA_CFLAGS="$EXTRA_CFLAGS -ffunction-sections -fdata-sections"
EXTRA_LDFLAGS="-gc-sections"

# --- 7. PGO flags (only if explicitly requested) ----------------------------
if [ "$PROFILE_GEN" = "1" ]; then
    echo "== PGO: building instrumented kernel (profile generation)"
    EXTRA_CFLAGS="$EXTRA_CFLAGS -fprofile-generate"
    EXTRA_LDFLAGS="$EXTRA_LDFLAGS -fprofile-generate"
elif [ -n "$PROFILE_USE" ]; then
    if [ -f "$PROFILE_USE" ]; then
        echo "== PGO: using profile: $PROFILE_USE"
        EXTRA_CFLAGS="$EXTRA_CFLAGS -fprofile-use=$PROFILE_USE"
        EXTRA_LDFLAGS="$EXTRA_LDFLAGS -fprofile-use=$PROFILE_USE"
    else
        echo "WARNING: PROFILE_USE file not found: $PROFILE_USE" >&2
    fi
fi

# --- 8. MLGO flags (if model available) -------------------------------------
if [ -n "$MLGO_MODEL" ] && [ -f "$MLGO_MODEL" ]; then
    echo "== MLGO: using model: $MLGO_MODEL"
    EXTRA_CFLAGS="$EXTRA_CFLAGS -fmlgo-inlining=$MLGO_MODEL"
fi

# --- 9. Build configuration -------------------------------------------------
# Fresh .config from veux_defconfig (tree was just mrproper'd in step 0)
echo "== Generating veux_defconfig"
make veux_defconfig

# --- 10. Enable ThinLTO (always) ------------------------------------------
if grep -q "^CONFIG_LTO_CLANG=y" .config && grep -q "^# CONFIG_THINLTO is not set" .config; then
    echo "!! Enabling ThinLTO (replacing full LTO)"
    sed -i 's/^# CONFIG_THINLTO is not set$/CONFIG_THINLTO=y/' .config
fi

# --- 11. Reconcile config non‑interactively --------------------------------
make olddefconfig

# --- 12. Build kernel ------------------------------------------------------
echo "== Starting build with $JOBS parallel jobs"
make -j"$JOBS" \
    ARCH=arm64 \
    LLVM=1 \
    LLVM_IAS=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KCFLAGS="$KCFLAGS $EXTRA_CFLAGS" \
    KCPPFLAGS="$KCPPFLAGS" \
    LDFLAGS="$EXTRA_LDFLAGS" \
    Image Image.gz dtbs 2>&1 | tee error.log

# --- 13. Post‑build BOLT optimization (if enabled) -------------------------
if [ "$BOLT_ENABLE" = "1" ] && [ -f vmlinux ]; then
    echo "== BOLT: optimizing vmlinux"
    cp -f vmlinux vmlinux.orig
    if llvm-bolt vmlinux -o vmlinux.bolt \
        -reorder-blocks=cache \
        -split-functions=3 \
        -icf=1 \
        -use-gnu-stack \
        -dyno-stats; then
        mv vmlinux.bolt vmlinux
        echo "== BOLT: regenerating Image and Image.gz"
        aarch64-linux-gnu-objcopy -O binary vmlinux arch/arm64/boot/Image
        gzip -f -9 -c arch/arm64/boot/Image > arch/arm64/boot/Image.gz
        cp -f arch/arm64/boot/Image .
        cp -f arch/arm64/boot/Image.gz .
        echo "== BOLT optimization completed."
    else
        echo "WARNING: BOLT failed; original vmlinux restored." >&2
        mv vmlinux.orig vmlinux
    fi
else
    echo "== BOLT skipped or vmlinux missing"
fi

echo "Build finished. Outputs: arch/arm64/boot/Image, Image.gz, dtbs/"
