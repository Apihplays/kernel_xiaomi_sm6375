#!/bin/bash
# ============================================================================
# build_veux.sh — veux (Redmi Note 11 Pro 5G, SM6375 / holi) 5.4 kernel build
#
# Kernel : 5.4.302 ACK, QGKI monolithic, ReSukiSU (CONFIG_KSU_MANUAL_HOOK)
# Config : arch/arm64/configs/veux_defconfig  (LOCALVERSION="-qgki", kept as-is)
# Outputs: arch/arm64/boot/Image, Image.gz, dtbs/ (+ copies placed in the
#          kernel root: ./Image, ./Image.gz, ./dtbs/)
# Log    : ./error.log (kernel root), override with LOG_FILE=
#
# Usage:
#   ./build_veux.sh            clean build (make clean + defconfig regen + build)
#   ./build_veux.sh --resume   incremental build (skip clean + defconfig regen)
#   ./build_veux.sh --check    verify ReSukiSU hook symbols in an existing Image
#
# Env overrides (existing):
#   TC_PATH   dir containing clang/ld.lld/llvm-* (default: autodetect)
#   JOBS      parallel jobs (default: nproc)
#   KCFLAGS / KCPPFLAGS        default: "-O2 -fvisibility=hidden -mcpu=cortex-a76" / "-O2"
#   CROSS_COMPILE              default: aarch64-linux-gnu-
#   KSU_FIX=0                  do NOT auto-enable KALLSYMS_ALL in .config
#   LTO_THIN=0                 keep FULL Clang LTO (default: enable ThinLTO)
#   LOG_FILE                   build log (default: ./error.log)
#   OUT_DIR                    where the AK3 zip is copied (default: Windows out)
#
# New optimizations – auto‑enabled when prerequisites are met:
#   MLGO_MODEL  path to MLGO model file (default: ~/mlgo-model.mlgo if exists)
#   BOLT        set to 0 to disable BOLT (auto‑enabled if llvm-bolt is found)
#
# PGO requires manual setup (two‑phase build):
#   PROFILE_GEN=1              build instrumented kernel for profile collection
#   PROFILE_USE=<path>         build using collected profile
# ============================================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# --- modes -------------------------------------------------------------------
MODE_BUILD=1
MODE_CHECK=0
MODE_RESUME=0
for arg in "$@"; do
    case "$arg" in
        --resume) MODE_RESUME=1 ;;
        --check)  MODE_CHECK=1; MODE_BUILD=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# --- toolchain ---------------------------------------------------------------
# Find a LLVM install that provides clang + ld.lld + llvm-ar (unsuffixed names).
# Priority: 1) our AOSP prebuilt Clang (clang-r596125)  2) system LLVM-22/23
if [ -z "${TC_PATH:-}" ]; then
    for d in "$HOME/toolchains/clang-r596125/bin" \
             /usr/lib/llvm-22/bin /usr/lib/llvm-23/bin /usr/lib/llvm-*/bin; do
        # shellcheck disable=SC2086
        if [ -x "$d/clang" ] && [ -x "$d/ld.lld" ] && [ -x "$d/llvm-ar" ]; then
            TC_PATH="$d"
            break
        fi
    done
fi
if [ -z "${TC_PATH:-}" ] || [ ! -x "$TC_PATH/clang" ]; then
    echo "ERROR: no LLVM toolchain found (need clang + ld.lld + llvm-ar)." >&2
    echo "       Set TC_PATH=/path/to/llvm/bin" >&2
    exit 1
fi
export PATH="$TC_PATH:$PATH"
echo "== Toolchain: $TC_PATH ($("$TC_PATH/clang" --version | head -1))"

# --- env ---------------------------------------------------------------------
export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export LLVM=1
export LLVM_IAS=1
ROOT="$(pwd)"   # kernel root (script dir after cd above)
JOBS="${JOBS:-$(nproc)}"
KCFLAGS="${KCFLAGS:--O2 -fvisibility=hidden -mcpu=cortex-a76}"
KCPPFLAGS="${KCPPFLAGS:--O2}"
LOG_FILE="${LOG_FILE:-$ROOT/error.log}"
OUT_DIR="${OUT_DIR:-/mnt/c/Users/Administrator/Documents/out}"
IMAGE=arch/arm64/boot/Image
IMAGE_GZ=arch/arm64/boot/Image.gz
VMLINUX=vmlinux

echo "== ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LLVM=1 LLVM_IAS=1"
echo "== JOBS=$JOBS  KCFLAGS=\"$KCFLAGS\"  KCPPFLAGS=\"$KCPPFLAGS\""
echo "== Log: $LOG_FILE"

# --- Optional optimizations – auto‑enable if prerequisites are met ----------
# PGO: turned ON by default for veux builds
#   Phase 1 (profile generation):  PROFILE_GEN=1          (no PROFILE_USE)
#   Phase 2 (profile use):         PROFILE_USE=<profile> (no PROFILE_GEN)
#   Normal build (no PGO):         leave both unset/0
PROFILE_GEN="${PROFILE_GEN:-1}"
PROFILE_USE="${PROFILE_USE:-}"

# MLGO: if MLGO_MODEL is not set, check for default ~/mlgo-model.mlgo
if [ -z "${MLGO_MODEL:-}" ]; then
    if [ -f "$HOME/mlgo-model.mlgo" ]; then
        MLGO_MODEL="$HOME/mlgo-model.mlgo"
        echo "== MLGO: auto‑enabled (found $MLGO_MODEL)"
    fi
fi

# BOLT: if BOLT env var is not set, auto‑enable if llvm-bolt exists
if [ -z "${BOLT:-}" ]; then
    if command -v llvm-bolt &>/dev/null; then
        BOLT_ENABLE=1
        echo "== BOLT: auto‑enabled (llvm-bolt found)"
    else
        BOLT_ENABLE=0
    fi
else
    BOLT_ENABLE="$BOLT"
fi

# --- KSU symbol check (shared by build + --check) ----------------------------
KSU_SYMBOLS=(ksu_handle_execveat ksu_handle_faccessat ksu_handle_stat \
             ksu_handle_newfstat_ret ksu_handle_fstat64_ret ksu_handle_sys_reboot)

check_ksu_symbols() {
    local img="${1:-$IMAGE}"
    [ -f "$img" ] || { echo "FAIL: $img not found" >&2; return 1; }
    local missing=0 sym
    for sym in "${KSU_SYMBOLS[@]}"; do
        if grep -aq "$sym" "$img"; then
            echo "  [OK] $sym"
        else
            echo "  [MISSING] $sym" >&2
            missing=1
        fi
    done
    return $missing
}

if [ "$MODE_CHECK" -eq 1 ]; then
    echo "== Checking ReSukiSU hooks in $IMAGE"
    check_ksu_symbols "$IMAGE"
    exit $?
fi

# --- clean + defconfig -------------------------------------------------------
if [ "$MODE_RESUME" -eq 0 ]; then
    echo "== make mrproper (full clean, removes .config too)"
    make mrproper 2>&1 | tee -a "$LOG_FILE"
    echo "== make veux_defconfig"
    make veux_defconfig 2>&1 | grep -v '^# configuration written' | tee -a "$LOG_FILE"
else
    echo "== Resume mode: skipping clean + defconfig regen"
    [ -f .config ] || { echo "ERROR: no .config; run without --resume first" >&2; exit 1; }
fi

# --- ReSukiSU required KALLSYMS_ALL (documented hard requirement) ------------
if grep -q "^CONFIG_KSU=y" .config && ! grep -q "^CONFIG_KALLSYMS_ALL=y" .config; then
    if [ "${KSU_FIX:-1}" = "1" ]; then
        echo "!! CONFIG_KALLSYMS_ALL is not set — ReSukiSU static_export_check.mk"
        echo "!! hard-fails without it (selinuxfs symbols are static upstream)."
        echo "!! Appending to generated .config (veux_defconfig left untouched)."
        sed -i '/^# CONFIG_DEBUG_KERNEL is not set$/d; /^CONFIG_DEBUG_KERNEL=/d; /^CONFIG_KALLSYMS_ALL=/d' .config
        cat >> .config <<'EOF'

# ReSukiSU requirement (auto-added by build_veux.sh)
CONFIG_DEBUG_KERNEL=y
CONFIG_KALLSYMS_ALL=y
EOF
    else
        echo "WARNING: CONFIG_KALLSYMS_ALL not set and KSU_FIX=0 — build will fail" >&2
    fi
fi

# --- ThinLTO (default: yes) -------------------------------------------------
# veux_defconfig disables THINLTO -> full Clang LTO at link time. arm64
# supports ThinLTO (ARCH_SUPPORTS_THINLTO=y) and Kconfig defaults it to y.
if [ "${LTO_THIN:-1}" = "1" ] && grep -q "^CONFIG_LTO_CLANG=y" .config \
   && grep -q "^# CONFIG_THINLTO is not set" .config; then
    echo "!! CONFIG_THINLTO is not set (full LTO) — enabling Clang ThinLTO"
    sed -i 's/^# CONFIG_THINLTO is not set$/CONFIG_THINLTO=y/' .config
fi

# --- reconcile .config (non-interactive) -------------------------------------
# Hand-edited/out-of-sync .config makes kbuild's syncconfig prompt for every
# y/n choice at build start. olddefconfig fills in all symbols silently and
# rewrites .config canonically, so `make` never asks questions.
echo "== make olddefconfig (reconcile .config, non-interactive)"
make olddefconfig 2>&1 | grep -v '^# configuration written' | tee -a "$LOG_FILE"

# --- prepare extra compiler/linker flags -------------------------------------
# Base safe flags (always applied)
KBUILD_CFLAGS=" -fno-builtin-wcslen -fno-strict-overflow -fno-merge-all-constants"
KBUILD_CFLAGS="$KBUILD_CFLAGS -ffunction-sections -fdata-sections"
KBUILD_LDFLAGS=" -gc-sections"

# PGO: instrumented or profile-use
if [ "$PROFILE_GEN" = "1" ]; then
    echo "== PGO: building instrumented kernel (profile generation)"
    KBUILD_CFLAGS="$KBUILD_CFLAGS -fprofile-generate"
    KBUILD_LDFLAGS="$KBUILD_LDFLAGS -fprofile-generate"
elif [ -n "$PROFILE_USE" ]; then
    if [ -f "$PROFILE_USE" ]; then
        echo "== PGO: using profile: $PROFILE_USE"
        KBUILD_CFLAGS="$KBUILD_CFLAGS -fprofile-use=$PROFILE_USE"
        KBUILD_LDFLAGS="$KBUILD_LDFLAGS -fprofile-use=$PROFILE_USE"
    else
        echo "WARNING: PROFILE_USE file not found: $PROFILE_USE" >&2
    fi
fi

# MLGO: if model file is specified and exists
if [ -n "${MLGO_MODEL:-}" ] && [ -f "$MLGO_MODEL" ]; then
    echo "== MLGO: using model: $MLGO_MODEL"
    KBUILD_CFLAGS="$KBUILD_CFLAGS -fmlgo-inlining=$MLGO_MODEL"
fi

export KBUILD_CFLAGS
export KBUILD_LDFLAGS

# --- build -------------------------------------------------------------------
TARGETS="Image Image.gz dtbs"
if grep -q "^CONFIG_MODULES=y" .config; then
    TARGETS="$TARGETS modules"
    echo "== CONFIG_MODULES=y — building modules too"
fi

echo "== make -j$JOBS $TARGETS"
if ! make -j"$JOBS" KCFLAGS="$KCFLAGS $KBUILD_CFLAGS" \
                    KCPPFLAGS="$KCPPFLAGS" \
                    LDFLAGS="$KBUILD_LDFLAGS" \
                    $TARGETS 2>&1 | tee -a "$LOG_FILE"; then
    echo "BUILD FAILED — see $LOG_FILE" >&2
    exit 1
fi

echo "== Verifying ReSukiSU hooks in $IMAGE"
check_ksu_symbols "$IMAGE" || echo "WARNING: some hooks missing (see above)" >&2

echo "== Outputs:"
ls -lh "$IMAGE" "$IMAGE_GZ" 2>/dev/null || true
echo "   dtbs: $(find arch/arm64/boot/dts -name '*.dtb' | wc -l) files"
echo "== Copying artifacts to kernel root: $ROOT"
cp -f "$IMAGE" "$ROOT/Image"
cp -f "$IMAGE_GZ" "$ROOT/Image.gz"
mkdir -p "$ROOT/dtbs"
find arch/arm64/boot/dts -name '*.dtb' -exec cp -f {} "$ROOT/dtbs/" \;
echo "   -> $ROOT/Image, $ROOT/Image.gz, $ROOT/dtbs/ ($(find "$ROOT/dtbs" -name '*.dtb' | wc -l) files)"

# --- BOLT post‑link optimization (optional) ----------------------------------
if [ "$BOLT_ENABLE" = "1" ]; then
    if ! command -v llvm-bolt &>/dev/null; then
        echo "WARNING: llvm-bolt not found; skipping BOLT optimization." >&2
    elif [ ! -f "$VMLINUX" ]; then
        echo "WARNING: $VMLINUX not found; skipping BOLT." >&2
    else
        echo "== BOLT: optimizing vmlinux"
        # Backup original vmlinux
        cp -f "$VMLINUX" "$VMLINUX.orig"
        # Run BOLT. Use cache-line aware optimizations.
        if llvm-bolt "$VMLINUX" -o "$VMLINUX.bolt" \
            -reorder-blocks=cache \
            -split-functions=3 \
            -icf=1 \
            -use-gnu-stack \
            -dyno-stats; then
            # Replace vmlinux with the bolt-optimized one
            mv "$VMLINUX.bolt" "$VMLINUX"
            echo "== BOLT: regenerating Image and Image.gz from optimized vmlinux"
            # Regenerate Image (binary) using objcopy
            if command -v aarch64-linux-gnu-objcopy &>/dev/null; then
                aarch64-linux-gnu-objcopy -O binary "$VMLINUX" "$IMAGE"
            else
                echo "WARNING: aarch64-linux-gnu-objcopy not found; skipping Image regen after BOLT" >&2
            fi
            # Re-compress to Image.gz
            gzip -f -9 -c "$IMAGE" > "$IMAGE_GZ"
            # Copy updated images to root
            cp -f "$IMAGE" "$ROOT/Image"
            cp -f "$IMAGE_GZ" "$ROOT/Image.gz"
            echo "== BOLT optimization completed."
        else
            echo "WARNING: BOLT optimization failed; original vmlinux restored." >&2
            mv "$VMLINUX.orig" "$VMLINUX"
        fi
    fi
fi

echo "BUILD SUCCESSFUL"

# --- optional AK3 zip packaging ----------------------------------------------
if [ -d AnyKernel3 ]; then
    STAMP=$(date +%Y%m%d)
    ZIP="positron-xxksu-veux-$STAMP.zip"
    echo "== Packaging AK3 zip: $ZIP"
    rm -rf /tmp/ak3_stage && mkdir -p /tmp/ak3_stage
    cp -r AnyKernel3/. /tmp/ak3_stage/
    cp "$IMAGE_GZ" /tmp/ak3_stage/Image.gz
    mkdir -p /tmp/ak3_stage/modules
    # dtb/: skipped — AnyKernel3/dtb is the single veux DTB blob; do not overwrite with a dir of all arch dtbs
    find . -name '*.ko' -exec cp {} /tmp/ak3_stage/modules/ \;
    # Build zip in /tmp (deterministic path), then copy to desired location
    (cd /tmp/ak3_stage && zip -q -r "/tmp/$ZIP" .)
    if [ -d "$OUT_DIR" ]; then
        cp "/tmp/$ZIP" "$OUT_DIR/"
        echo "== Copied $ZIP -> $OUT_DIR"
    else
        cp "/tmp/$ZIP" "$ROOT/$ZIP"
        echo "== $OUT_DIR not mounted; zip left at $ROOT/$ZIP"
    fi
else
    echo "== AnyKernel3/ not present — skipping zip packaging"
fi
