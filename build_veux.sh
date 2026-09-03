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
# Env overrides:
#   TC_PATH   dir containing clang/ld.lld/llvm-* (default: autodetect llvm-22+)
#   JOBS      parallel jobs (default: nproc = all cores)
#   KCFLAGS / KCPPFLAGS        default: "-O2 -fvisibility=hidden -mcpu=cortex-a76" / "-O2"
#   CROSS_COMPILE              default: aarch64-linux-gnu-
#   KSU_FIX=0                  do NOT auto-enable KALLSYMS_ALL in .config
#   LOG_FILE                   build log (default: ./error.log in kernel root)
#   OUT_DIR                    where the AK3 zip is copied (default: Windows out)
#
# Notes:
#   - Uses LLVM=1 (clang + lld + llvm-binutils) with clang's integrated assembler.
#   - KSU syscall hooks and backports (path_umount, strncpy_from_user_nofault,
#     seccomp filter_count) are ALREADY applied in the tree — do not re-run
#     syscall_hook_patches.sh / backport_patches.sh.
#   - ReSukiSU's static_export_check.mk hard-fails without CONFIG_KALLSYMS_ALL=y.
#     The script auto-appends DEBUG_KERNEL + KALLSYMS_ALL to the generated
#     .config (NOT to veux_defconfig) when CONFIG_KSU=y and it is missing.
#     Set KSU_FIX=0 to disable.
#   - Runs `make olddefconfig` after config setup so kbuild's syncconfig never
#     prompts for y/n choices (hand-appended KALLSYMS entries otherwise trigger
#     interactive "Restart config..." at build start).
#   - AK3 zip step is skipped unless ./AnyKernel3 exists (it was removed).
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
# Preferred: ~/toolchains/LLVM-23.1.0-Linux-X64 (clang 23.1.0, full release —
# its lib/ also carries the ICU 70 .so's lld needs). Fallback: system clang-22.
if [ -z "${TC_PATH:-}" ]; then
    for d in /home/pro95/toolchains/LLVM-23.1.0-Linux-X64/bin \
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

echo "== ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LLVM=1 LLVM_IAS=1"
echo "== JOBS=$JOBS  KCFLAGS=\"$KCFLAGS\"  KCPPFLAGS=\"$KCPPFLAGS\""
echo "== Log: $LOG_FILE"

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
    echo "== make clean"
    make clean 2>&1 | tee -a "$LOG_FILE"
    echo "== make veux_defconfig"
    make veux_defconfig 2>&1 | tee -a "$LOG_FILE"
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

# --- reconcile .config (non-interactive) -------------------------------------
# Hand-edited/out-of-sync .config makes kbuild's syncconfig prompt for every
# y/n choice at build start. olddefconfig fills in all symbols silently and
# rewrites .config canonically, so `make` never asks questions.
echo "== make olddefconfig (reconcile .config, non-interactive)"
make olddefconfig 2>&1 | tee -a "$LOG_FILE"

# --- build -----------------------------------------------------------------------------------------------------------------------------------
TARGETS="Image Image.gz dtbs"
if grep -q "^CONFIG_MODULES=y" .config; then
    TARGETS="$TARGETS modules"
    echo "== CONFIG_MODULES=y — building modules too"
fi

echo "== make -j$JOBS $TARGETS"
if ! make -j"$JOBS" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS" $TARGETS 2>&1 | tee -a "$LOG_FILE"; then
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
echo "BUILD SUCCESSFUL"

# --- optional AK3 zip packaging ----------------------------------------------
if [ -d AnyKernel3 ]; then
    STAMP=$(date +%Y%m%d)
    ZIP="positron-xxksu-veux-$STAMP.zip"
    echo "== Packaging AK3 zip: $ZIP"
    rm -rf /tmp/ak3_stage && mkdir -p /tmp/ak3_stage
    cp -r AnyKernel3/. /tmp/ak3_stage/
    cp "$IMAGE_GZ" /tmp/ak3_stage/Image.gz
    mkdir -p /tmp/ak3_stage/dtb /tmp/ak3_stage/modules
    find arch/arm64/boot/dts -name '*.dtb' -exec cp {} /tmp/ak3_stage/dtb/ \;
    find . -name '*.ko' -exec cp {} /tmp/ak3_stage/modules/ \;
    (cd /tmp/ak3_stage && zip -q -r "$OLDPWD/$ZIP" .)
    if [ -d "$OUT_DIR" ]; then
        cp "$ZIP" "$OUT_DIR/"
        echo "== Copied $ZIP -> $OUT_DIR"
    else
        echo "== $OUT_DIR not mounted; zip left at ./$ZIP"
    fi
else
    echo "== AnyKernel3/ not present — skipping zip packaging"
fi