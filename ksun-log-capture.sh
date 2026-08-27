#!/bin/bash
# ksun-log-capture.sh — Comprehensive diagnostic & crash log puller for veux
# Handles: root via `adb root`, root via `su`, non-root fallback
#
# Usage:
#   ./ksun-log-capture.sh [output_dir]
#   ./ksun-log-capture.sh setup   (run on working kernel before test)
#   ./ksun-log-capture.sh pull    (run after crash/reboot)
#
set -euo pipefail

ACTION="${1:-pull}"
OUT=""

if [ "$ACTION" = "setup" ] || [ "$ACTION" = "pull" ]; then
    OUT="${2:-./diag-$(date +%Y%m%d-%H%M%S)}"
else
    OUT="$ACTION"
    ACTION="pull"
fi

# ── Helpers ──────────────────────────────────────────────────
run_adb() {
    adb shell "$@" 2>/dev/null || true
}

run_root() {
    # Try 1: direct shell (if adbd is root)
    if [ "$HAS_ADB_ROOT" = "1" ]; then
        adb shell "$@" 2>/dev/null || true
    # Try 2: su -c
    elif [ "$HAS_SU" = "1" ]; then
        adb shell "su -c '$*'" 2>/dev/null || true
    # Try 3: plain shell (best effort)
    else
        adb shell "$@" 2>/dev/null || true
    fi
}

# ── Check Device ─────────────────────────────────────────────
if ! adb devices 2>/dev/null | grep -q 'device$'; then
    echo "[ERROR] No device connected via ADB."
    echo "  1. Connect phone via USB"
    echo "  2. Ensure USB debugging is ON"
    echo "  3. Accept RSA prompt if shown"
    exit 1
fi

echo "================================================="
echo "  veux Kernel Diagnostic Capture"
echo "  Mode   : $ACTION"
echo "  Output : $OUT"
echo "================================================="

# ── Root Detection ───────────────────────────────────────────
echo "[*] Checking root capabilities..."
HAS_ADB_ROOT=0
HAS_SU=0

# Try adb root first (enabled by androidboot.debuggable=1)
if adb root 2>&1 | grep -q 'restarting adbd as root\|already running as root'; then
    sleep 1
    HAS_ADB_ROOT=1
    echo "  [+] adb root: AVAILABLE (adbd running as root)"
else
    echo "  [-] adb root: NOT available"
fi

# Check su availability
if [ "$HAS_ADB_ROOT" = "0" ]; then
    if adb shell "which su" 2>/dev/null | grep -q 'su'; then
        HAS_SU=1
        echo "  [+] su binary: FOUND"
    else
        echo "  [-] su binary: NOT found"
    fi
fi

if [ "$HAS_ADB_ROOT" = "0" ] && [ "$HAS_SU" = "0" ]; then
    echo "  [!] Running in NON-ROOT mode (some kernel logs may be restricted)"
fi

# ── SETUP MODE ───────────────────────────────────────────────
if [ "$ACTION" = "setup" ]; then
    echo ""
    echo "[+] Preparing device for crash capture..."
    run_root "logpersist.start"
    run_root "echo 1 > /proc/sys/kernel/printk_devkmsg"
    adb shell "logcat -G 16M" 2>/dev/null || true
    
    mkdir -p "$OUT/baseline"
    run_root "uname -a" > "$OUT/baseline/kernel.txt"
    run_root "cat /proc/cmdline" > "$OUT/baseline/cmdline.txt"
    run_root "getenforce" > "$OUT/baseline/selinux.txt"
    run_root "dmesg" > "$OUT/baseline/dmesg.txt"
    adb logcat -d -b all > "$OUT/baseline/logcat.txt" 2>/dev/null || true
    
    echo ""
    echo "=== Baseline Saved ==="
    echo "  Kernel : $(cat "$OUT/baseline/kernel.txt" 2>/dev/null || echo 'unknown')"
    echo "  SELinux: $(cat "$OUT/baseline/selinux.txt" 2>/dev/null || echo 'unknown')"
    echo ""
    echo "Next: Flash test kernel → trigger crash → run ./ksun-log-capture.sh pull"
    exit 0
fi

# ── PULL MODE (Full Diagnostic) ──────────────────────────────
mkdir -p "$OUT"

echo ""
echo "[1/12] Device Identification..."
run_adb "getprop ro.product.model" > "$OUT/model.txt"
run_adb "getprop ro.build.display.id" > "$OUT/build-id.txt"
run_adb "getprop ro.build.version.release" > "$OUT/android-version.txt"
run_adb "getprop ro.product.board" > "$OUT/board.txt"
run_adb "getprop ro.hardware" > "$OUT/hardware.txt"
run_adb "getprop ro.boot.slot_suffix" > "$OUT/slot.txt"

echo "[2/12] Kernel & Boot Info..."
run_root "uname -a" > "$OUT/kernel-version.txt"
run_root "cat /proc/version" > "$OUT/proc-version.txt"
run_root "cat /proc/cmdline" > "$OUT/cmdline.txt"
run_root "cat /proc/uptime" > "$OUT/uptime.txt"

echo "[3/12] Dmesg (Kernel Log)..."
run_root "dmesg" > "$OUT/dmesg.txt"
if [ -s "$OUT/dmesg.txt" ]; then
    grep -iE 'panic|oops|bug:|fatal|call trace|cut here|kernel NULL' "$OUT/dmesg.txt" > "$OUT/dmesg-panics.txt" 2>/dev/null || true
    grep -iE 'sde|dsi|drm|display|panel|mdss|composer|hwc' "$OUT/dmesg.txt" > "$OUT/dmesg-display.txt" 2>/dev/null || true
    grep -iE 'fingerprint|silead|fpc|goodix|synna' "$OUT/dmesg.txt" > "$OUT/dmesg-fingerprint.txt" 2>/dev/null || true
    grep -iE 'avc:.*denied' "$OUT/dmesg.txt" > "$OUT/dmesg-avc-denials.txt" 2>/dev/null || true
    echo "  [+] dmesg: $(wc -l < "$OUT/dmesg.txt") lines captured"
else
    echo "  [-] dmesg: empty (needs root)"
fi

echo "[4/12] Crash Logs & Pstore (Previous Boot)..."
run_root "cat /sys/fs/pstore/console-ramdump-0" > "$OUT/pstore-console.txt"
run_root "cat /sys/fs/pstore/dmesg-ramoops-0" > "$OUT/pstore-dmesg.txt"
run_root "cat /proc/last_kmsg" > "$OUT/last_kmsg.txt"
run_root "ls -la /sys/fs/pstore/" > "$OUT/pstore-files.txt"

echo "[5/12] Logcat (System Logs)..."
adb logcat -d -b crash > "$OUT/logcat-crash.txt" 2>/dev/null || true
adb logcat -d -b main,system,events -v time > "$OUT/logcat-main.txt" 2>/dev/null || true
if [ -s "$OUT/logcat-crash.txt" ]; then
    echo "  [+] Crash logcat: $(wc -l < "$OUT/logcat-crash.txt") lines"
fi

echo "[6/12] Tombstones & ANR (Native Process Crashes)..."
run_root "ls -la /data/tombstones/" > "$OUT/tombstones-list.txt"
for i in 00 01 02 03 04; do
    run_root "cat /data/tombstones/tombstone_$i" > "$OUT/tombstone_$i.txt"
    [ ! -s "$OUT/tombstone_$i.txt" ] && rm -f "$OUT/tombstone_$i.txt"
done
run_root "ls -la /data/anr/" > "$OUT/anr-list.txt"

echo "[7/12] SELinux Status & Violations..."
run_root "getenforce" > "$OUT/selinux-mode.txt"
run_root "cat /proc/filesystems" > "$OUT/filesystems.txt"
if [ -s "$OUT/logcat-main.txt" ]; then
    grep -i 'avc.*denied' "$OUT/logcat-main.txt" > "$OUT/logcat-avc-denials.txt" 2>/dev/null || true
fi

echo "[8/12] Display & Graphics Stack..."
run_adb "dumpsys display" > "$OUT/dumpsys-display.txt"
run_adb "dumpsys SurfaceFlinger" > "$OUT/dumpsys-surfaceflinger.txt"
run_adb "dumpsys SurfaceFlinger --latency" > "$OUT/surfaceflinger-latency.txt"

echo "[9/12] Input & Biometrics..."
run_adb "dumpsys input" > "$OUT/dumpsys-input.txt"
run_adb "dumpsys fingerprint" > "$OUT/dumpsys-fingerprint.txt"
run_adb "dumpsys biometric" > "$OUT/dumpsys-biometric.txt"

echo "[10/12] Power & Keyguard..."
run_adb "dumpsys power" > "$OUT/dumpsys-power.txt"
run_adb "dumpsys window" > "$OUT/dumpsys-window.txt"

echo "[11/12] Partitions & Storage..."
run_root "ls -la /dev/block/bootdevice/by-name/" > "$OUT/partitions.txt"
run_root "df -h" > "$OUT/df.txt"
run_root "cat /proc/mounts" > "$OUT/mounts.txt"

echo "[12/12] Kernel Config & Modules..."
run_root "cat /proc/config.gz | gunzip" > "$OUT/running-config.txt" 2>/dev/null || true
run_root "lsmod" > "$OUT/lsmod.txt"
run_root "cat /proc/modules" > "$OUT/proc-modules.txt"

# ── Summary Report ───────────────────────────────────────────
echo ""
echo "================================================="
echo "  Capture Complete — Summary"
echo "================================================="
echo "  Output Directory : $OUT/"
echo "  Files Captured   :"

for f in "$OUT"/*; do
    if [ -f "$f" ] && [ -s "$f" ]; then
        printf "    %-30s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    fi
done

echo ""
echo "  Key files to check first for soft-reboot on unlock:"
[ -s "$OUT/dmesg-panics.txt" ]       && echo "    🔴 $OUT/dmesg-panics.txt (KERNEL PANIC FOUND!)"
[ -s "$OUT/logcat-crash.txt" ]       && echo "    🟡 $OUT/logcat-crash.txt (Process crash)"
[ -s "$OUT/pstore-console.txt" ]     && echo "    🟡 $OUT/pstore-console.txt (Previous crash log)"
[ -s "$OUT/dmesg-avc-denials.txt" ]  && echo "    🟡 $OUT/dmesg-avc-denials.txt (SELinux denials)"
[ -s "$OUT/dmesg-fingerprint.txt" ]  && echo "    🔵 $OUT/dmesg-fingerprint.txt (Fingerprint HAL logs)"
[ -s "$OUT/dmesg-display.txt" ]      && echo "    🔵 $OUT/dmesg-display.txt (Display driver logs)"
echo "================================================="
