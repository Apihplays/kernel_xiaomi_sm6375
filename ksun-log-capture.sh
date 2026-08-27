#!/bin/bash
# ksun-log-capture.sh — Hardened diagnostic & live crash capture for veux
#
# Modes:
#   ./ksun-log-capture.sh monitor  → Streams logs live while you unlock screen (BEST for crash)
#   ./ksun-log-capture.sh pull     → Pulls complete 14-category post-mortem dump
#   ./ksun-log-capture.sh setup    → Captures baseline on working kernel
#
set -euo pipefail

ACTION="${1:-pull}"
OUT=""

if [ "$ACTION" = "setup" ] || [ "$ACTION" = "pull" ] || [ "$ACTION" = "monitor" ]; then
    OUT="${2:-./diag-$(date +%Y%m%d-%H%M%S)}"
else
    OUT="$ACTION"
    ACTION="pull"
fi

TIMEOUT_SEC=10

# ── Safe execution helpers with timeouts ─────────────────────
run_adb_cmd() {
    timeout "$TIMEOUT_SEC" adb shell "$@" 2>/dev/null || true
}

run_root_cmd() {
    if [ "$HAS_ADB_ROOT" = "1" ]; then
        timeout "$TIMEOUT_SEC" adb shell "$@" 2>/dev/null || true
    elif [ "$HAS_SU" = "1" ]; then
        timeout "$TIMEOUT_SEC" adb shell "su 0 sh -c '$*'" 2>/dev/null || true
    else
        timeout "$TIMEOUT_SEC" adb shell "$@" 2>/dev/null || true
    fi
}

# ── Check Device ─────────────────────────────────────────────
if ! adb devices 2>/dev/null | grep -q 'device$'; then
    echo "[ERROR] No device connected via ADB."
    exit 1
fi

echo "================================================="
echo "  veux Kernel Diagnostic Capture v2.0"
echo "  Mode   : $ACTION"
echo "  Output : $OUT"
echo "================================================="

# ── Root Detection ───────────────────────────────────────────
echo "[*] Detecting root capabilities..."
HAS_ADB_ROOT=0
HAS_SU=0

if adb root 2>&1 | grep -q 'restarting adbd as root\|already running as root'; then
    sleep 1
    HAS_ADB_ROOT=1
    echo "  [+] adb root: ACTIVE"
elif adb shell "which su" 2>/dev/null | grep -q 'su'; then
    HAS_SU=1
    echo "  [+] su binary: ACTIVE"
else
    echo "  [!] Running in NON-ROOT mode"
fi

# ═════════════════════════════════════════════════════════════
# MODE 1: LIVE MONITOR (Streams to host disk in real-time)
# ═════════════════════════════════════════════════════════════
if [ "$ACTION" = "monitor" ]; then
    mkdir -p "$OUT"
    echo ""
    echo "[+] Starting LIVE streaming logs to host PC ($OUT/)..."
    echo "    - $OUT/live-logcat.log"
    echo "    - $OUT/live-dmesg.log"
    echo ""

    # Start live streams in background
    adb logcat -v time -b all > "$OUT/live-logcat.log" 2>&1 &
    LOGCAT_PID=$!

    if [ "$HAS_ADB_ROOT" = "1" ]; then
        adb shell "dmesg -w" > "$OUT/live-dmesg.log" 2>&1 &
        DMESG_PID=$!
    elif [ "$HAS_SU" = "1" ]; then
        adb shell "su 0 sh -c 'dmesg -w'" > "$OUT/live-dmesg.log" 2>&1 &
        DMESG_PID=$!
    else
        DMESG_PID=""
    fi

    echo "=========================================================="
    echo "  >>> READY! NOW UNLOCK YOUR PHONE TO TRIGGER CRASH <<<"
    echo "  Press Ctrl+C when phone soft-reboots or you are done."
    echo "=========================================================="

    cleanup() {
        echo ""
        echo "[*] Stopping live monitors..."
        kill $LOGCAT_PID 2>/dev/null || true
        [ -n "$DMESG_PID" ] && kill $DMESG_PID 2>/dev/null || true
        
        echo "[*] Analyzing captured live stream for root cause..."
        grep -iE 'fatal|panic|oops|backtrace|abort|sigsegv|sigabrt|died' "$OUT/live-logcat.log" > "$OUT/crash-summary-logcat.txt" 2>/dev/null || true
        [ -f "$OUT/live-dmesg.log" ] && grep -iE 'panic|oops|bug:|fatal|call trace|cut here' "$OUT/live-dmesg.log" > "$OUT/crash-summary-dmesg.txt" 2>/dev/null || true
        
        echo "=== Quick Crash Triage ==="
        if [ -s "$OUT/crash-summary-dmesg.txt" ]; then
            echo "🔴 KERNEL PANIC FOUND IN LIVE DMESG:"
            head -15 "$OUT/crash-summary-dmesg.txt"
        elif [ -s "$OUT/crash-summary-logcat.txt" ]; then
            echo "🟡 USERSPACE CRASH FOUND IN LIVE LOGCAT:"
            head -15 "$OUT/crash-summary-logcat.txt"
        else
            echo "ℹ️ No obvious panic strings in top filter — check raw files in $OUT/"
        fi
        exit 0
    }
    trap cleanup INT TERM

    # Keep watching connection
    while true; do
        if ! adb devices 2>/dev/null | grep -q 'device$'; then
            echo "[!] Device disconnected / rebooted!"
            sleep 2
            cleanup
        fi
        sleep 1
    done
fi

# ═════════════════════════════════════════════════════════════
# MODE 2: SETUP BASELINE
# ═════════════════════════════════════════════════════════════
if [ "$ACTION" = "setup" ]; then
    mkdir -p "$OUT/baseline"
    echo "[+] Capturing system baseline before flashing..."
    run_root_cmd "logpersist.start"
    run_root_cmd "echo 1 > /proc/sys/kernel/printk_devkmsg"
    adb shell "logcat -G 16M" 2>/dev/null || true
    
    run_root_cmd "uname -a" > "$OUT/baseline/kernel.txt"
    run_root_cmd "cat /proc/cmdline" > "$OUT/baseline/cmdline.txt"
    run_root_cmd "getenforce" > "$OUT/baseline/selinux.txt"
    run_root_cmd "dmesg" > "$OUT/baseline/dmesg.txt"
    adb logcat -d -b all > "$OUT/baseline/logcat.txt" 2>/dev/null || true
    
    echo "=== Baseline Saved to $OUT/baseline/ ==="
    exit 0
fi

# ═════════════════════════════════════════════════════════════
# MODE 3: FULL POST-MORTEM DUMP (PULL)
# ═════════════════════════════════════════════════════════════
mkdir -p "$OUT"

echo ""
echo "[1/14] Device & Slot..."
run_adb_cmd "getprop ro.product.model" > "$OUT/model.txt"
run_adb_cmd "getprop ro.build.display.id" > "$OUT/build-id.txt"
run_adb_cmd "getprop ro.build.version.release" > "$OUT/android-version.txt"
run_adb_cmd "getprop ro.boot.slot_suffix" > "$OUT/slot.txt"

echo "[2/14] Kernel & Cmdline..."
run_root_cmd "uname -a" > "$OUT/kernel-version.txt"
run_root_cmd "cat /proc/version" > "$OUT/proc-version.txt"
run_root_cmd "cat /proc/cmdline" > "$OUT/cmdline.txt"
run_root_cmd "cat /proc/uptime" > "$OUT/uptime.txt"

echo "[3/14] Kernel Dmesg & Subsystem Filters..."
run_root_cmd "dmesg" > "$OUT/dmesg.txt"
if [ -s "$OUT/dmesg.txt" ]; then
    grep -iE 'panic|oops|bug:|fatal|call trace|cut here|kernel NULL' "$OUT/dmesg.txt" > "$OUT/dmesg-panics.txt" 2>/dev/null || true
    grep -iE 'sde|dsi|drm|display|panel|mdss|composer|hwc' "$OUT/dmesg.txt" > "$OUT/dmesg-display.txt" 2>/dev/null || true
    grep -iE 'fingerprint|silead|fpc|goodix|synna' "$OUT/dmesg.txt" > "$OUT/dmesg-fingerprint.txt" 2>/dev/null || true
    grep -iE 'avc:.*denied' "$OUT/dmesg.txt" > "$OUT/dmesg-avc-denials.txt" 2>/dev/null || true
fi

echo "[4/14] Crash RAM Dumps (pstore & last_kmsg)..."
run_root_cmd "cat /sys/fs/pstore/console-ramdump-0" > "$OUT/pstore-console.txt"
run_root_cmd "cat /sys/fs/pstore/dmesg-ramoops-0" > "$OUT/pstore-dmesg.txt"
run_root_cmd "cat /proc/last_kmsg" > "$OUT/last_kmsg.txt"
run_root_cmd "ls -la /sys/fs/pstore/" > "$OUT/pstore-files.txt"

echo "[5/14] System Dropbox Crash Logs (SystemServer Forensics)..."
run_adb_cmd "dumpsys dropbox --print system_server_crash" > "$OUT/dropbox-system-server-crash.txt"
run_adb_cmd "dumpsys dropbox --print system_server_wtf" > "$OUT/dropbox-system-server-wtf.txt"
run_adb_cmd "dumpsys dropbox --print system_app_crash" > "$OUT/dropbox-system-app-crash.txt"
run_adb_cmd "dumpsys dropbox --print data_app_crash" > "$OUT/dropbox-data-app-crash.txt"
run_adb_cmd "dumpsys dropbox --print SYSTEM_TOMBSTONE" > "$OUT/dropbox-tombstone.txt"

echo "[6/14] Logcat (Crash & System Buffers)..."
adb logcat -d -b crash > "$OUT/logcat-crash.txt" 2>/dev/null || true
adb logcat -d -b main,system -v time > "$OUT/logcat-main.txt" 2>/dev/null || true

echo "[7/14] Native Tombstones..."
run_root_cmd "ls -la /data/tombstones/" > "$OUT/tombstones-list.txt"
for i in 00 01 02 03 04 05; do
    run_root_cmd "cat /data/tombstones/tombstone_$i" > "$OUT/tombstone_$i.txt"
    [ ! -s "$OUT/tombstone_$i.txt" ] && rm -f "$OUT/tombstone_$i.txt"
done

echo "[8/14] Binder IPC & Deadlock Diagnostics..."
run_root_cmd "cat /sys/kernel/debug/binder/failed_transaction_log" > "$OUT/binder-failed-transactions.txt"
run_root_cmd "cat /sys/kernel/debug/binder/transaction_log" > "$OUT/binder-transactions.txt"
run_root_cmd "cat /sys/kernel/debug/binder/state" > "$OUT/binder-state.txt"

echo "[9/14] SELinux Mode & Policy Violations..."
run_root_cmd "getenforce" > "$OUT/selinux-mode.txt"
if [ -s "$OUT/logcat-main.txt" ]; then
    grep -i 'avc.*denied' "$OUT/logcat-main.txt" > "$OUT/logcat-avc-denials.txt" 2>/dev/null || true
fi

echo "[10/14] Display, HWC & SurfaceFlinger..."
run_adb_cmd "dumpsys display" > "$OUT/dumpsys-display.txt"
run_adb_cmd "dumpsys SurfaceFlinger" > "$OUT/dumpsys-surfaceflinger.txt"
run_adb_cmd "dumpsys SurfaceFlinger --latency" > "$OUT/surfaceflinger-latency.txt"

echo "[11/14] Input, Biometrics & Keyguard..."
run_adb_cmd "dumpsys input" > "$OUT/dumpsys-input.txt"
run_adb_cmd "dumpsys fingerprint" > "$OUT/dumpsys-fingerprint.txt"
run_adb_cmd "dumpsys biometric" > "$OUT/dumpsys-biometric.txt"
run_adb_cmd "dumpsys window" > "$OUT/dumpsys-window.txt"

echo "[12/14] CPU Frequencies, Clocks & Thermals..."
run_root_cmd "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq" > "$OUT/cpu-freqs.txt"
run_root_cmd "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" > "$OUT/cpu-governors.txt"
run_root_cmd "cat /sys/class/thermal/thermal_zone*/temp" > "$OUT/thermal-temps.txt"

echo "[13/14] Storage, Mounts & Partitions..."
run_root_cmd "ls -la /dev/block/bootdevice/by-name/" > "$OUT/partitions.txt"
run_root_cmd "cat /proc/mounts" > "$OUT/mounts.txt"

echo "[14/14] Running Kernel Config & Loaded Modules..."
run_root_cmd "cat /proc/config.gz | gunzip" > "$OUT/running-config.txt" 2>/dev/null || true
run_root_cmd "lsmod" > "$OUT/lsmod.txt"

# ── Final Triage Summary ─────────────────────────────────────
echo ""
echo "================================================="
echo "  Capture Complete — Root Cause Triage"
echo "================================================="

FOUND_ISSUES=0

if [ -s "$OUT/dmesg-panics.txt" ]; then
    echo "🔴 [CRITICAL] Kernel panic found in dmesg:"
    head -5 "$OUT/dmesg-panics.txt"
    FOUND_ISSUES=1
fi

if [ -s "$OUT/dropbox-system-server-crash.txt" ]; then
    echo "🔴 [CRITICAL] system_server crash recorded in Dropbox:"
    grep -E 'Process:|Flags:|Subject:|FATAL EXCEPTION' "$OUT/dropbox-system-server-crash.txt" | head -5
    FOUND_ISSUES=1
fi

if [ -s "$OUT/pstore-console.txt" ]; then
    echo "🟡 [WARNING] Prior crash console dump exists in pstore"
    FOUND_ISSUES=1
fi

if [ -s "$OUT/logcat-crash.txt" ]; then
    echo "🟡 [WARNING] Process crash detected in logcat:"
    head -5 "$OUT/logcat-crash.txt"
    FOUND_ISSUES=1
fi

if [ "$FOUND_ISSUES" = "0" ]; then
    echo "✅ No obvious crash signatures found in standard buffers."
    echo "   Inspect raw logs in: $OUT/"
fi
echo "================================================="
