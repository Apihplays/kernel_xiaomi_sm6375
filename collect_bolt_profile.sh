#!/bin/bash
# ============================================================================
# collect_bolt_profile.sh -- capture kernel perf samples on the device and
# convert them to BOLT .fdata for profile-guided (PGO) BOLT builds.
#
# Flow:
#   1. Build + flash the kernel you want to profile (vmlinux MUST match the
#      running kernel so perf2bolt resolves symbols exactly).
#   2. Boot, root (KernelSU), authorize adb.
#   3. Run this script while you exercise the device (UI, apps, benchmarks).
#   4. Rebuild with the produced profile:
#        BOLT_ENABLE=1 LTO_MODE=none BOLT_FDATA=vmlinux.fdata ./build_veux.sh
#
# Notes:
#   - CONFIG_PERF_EVENTS=y is required (already set in veux_defconfig).
#   - /system/bin/perf must exist on the device (stock PixelOS has it).
#   - `nokaslr` on the kernel cmdline while collecting is recommended so raw
#     IPs line up with vmlinux; .fdata itself is function-name based, so a
#     KASLR slide is tolerated but may drop a few samples.
#
# Usage: ./collect_bolt_profile.sh [duration_seconds] [vmlinux_path]
#   env: PERF2BOLT=/path/to/perf2bolt (default: perf2bolt on PATH)
# ============================================================================
set -euo pipefail

DURATION="${1:-120}"
VMLINUX="${2:-vmlinux}"

if [ -n "${PERF2BOLT:-}" ]; then
    :
elif command -v perf2bolt >/dev/null 2>&1; then
    PERF2BOLT="$(command -v perf2bolt)"
else
    for cand in \
        /home/hayyan/toolchains/*/bin/perf2bolt \
        "$HOME"/bin/perf2bolt \
        "$HOME"/.local/bin/perf2bolt; do
        [ -x "$cand" ] && { PERF2BOLT="$cand"; break; }
    done
fi

if [ ! -f "$VMLINUX" ]; then
    echo "error: vmlinux not found at $VMLINUX" >&2
    exit 1
fi

if [ -z "${PERF2BOLT:-}" ] || [ ! -x "$PERF2BOLT" ]; then
    echo "error: perf2bolt not found. Point it via PERF2BOLT=, e.g.:" >&2
    echo "  PERF2BOLT=/home/hayyan/toolchains/clang-r596125/bin/perf2bolt" >&2
    exit 1
fi
echo "== perf2bolt: $PERF2BOLT"

# --- device reachable? rooted? ----------------------------------------------
if ! adb get-state 2>/dev/null | grep -q device; then
    echo "error: no device connected via adb" >&2
    exit 1
fi
echo "== device: $(adb shell getprop ro.product.vendor.model 2>/dev/null)"

if adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
    echo "== root: ok (KernelSU)"
else
    echo "error: root unavailable over 'su'" >&2
    exit 1
fi

# --- allow kernel profiling --------------------------------------------------
if adb shell "su -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'" 2>/dev/null \
   || adb shell "su -c 'sysctl -w kernel.perf_event_paranoid=-1'" 2>/dev/null; then
    echo "== kernel.perf_event_paranoid set to -1"
else
    echo "warning: could not set perf_event_paranoid; kernel samples may be dropped" >&2
fi

if ! adb shell "su -c 'test -x /system/bin/perf && echo yes'" | grep -q yes; then
    echo "warning: /system/bin/perf not found on device" >&2
fi

# --- capture -----------------------------------------------------------------
echo "== capturing ${DURATION}s system-wide (-a -g); exercise the phone now"
adb shell "su -c 'rm -f /data/local/tmp/perf.data /data/local/tmp/perf.data.old'"
if ! adb shell "su -c 'perf record -a -g -o /data/local/tmp/perf.data -- sleep ${DURATION}'"; then
    echo "error: perf record failed on device (run manually to see the reason)" >&2
    exit 1
fi

adb pull /data/local/tmp/perf.data perf.data >/dev/null
adb shell "su -c 'rm -f /data/local/tmp/perf.data'"
echo "== pulled perf.data ($(stat -c%s perf.data) bytes)"

# --- convert to BOLT profile ------------------------------------------------
echo "== perf2bolt -p perf.data -o vmlinux.fdata $VMLINUX"
perf2bolt -p perf.data -o vmlinux.fdata "$VMLINUX"

echo
echo "Done. Rebuild with the profile now:"
echo "  BOLT_ENABLE=1 LTO_MODE=none BOLT_FDATA=vmlinux.fdata ./build_veux.sh"