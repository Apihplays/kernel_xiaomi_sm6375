#!/bin/bash
# ================================================================
# veux_master_collector.sh — Hardened Unified Diagnostic Tool v2.0
# Target: Redmi Note 11 Pro 5G (veux / SM6375) · PixelOS A16/A17
# ================================================================
set -uo pipefail

DEVICE_CODENAME="veux"
SOC="SM6375"
ROM="PixelOS"
MODE="${1:-full}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="./veux_logs_${TIMESTAMP}"
DEVICE_TMP="/sdcard/veux_debug_tmp"
TIMEOUT_SEC=10

USE_ADB_ROOT=false
USE_SU=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }
title() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

strip_cr() {
    tr -d '\r'
}

check_adb() {
    if ! command -v adb &>/dev/null; then
        error "adb not found in PATH. Install android platform-tools."
        exit 1
    fi
    if ! adb devices 2>/dev/null | grep -q "device$"; then
        error "No authorized device detected via ADB. Check USB cable and debugging prompt."
        exit 1
    fi
    log "Device connected: $(adb devices | grep 'device$' | awk '{print $1}')"
}

gain_root() {
    title "Root Capability Detection"
    if adb root 2>&1 | grep -qE "restarting adbd as root|already running as root"; then
        sleep 1
        adb wait-for-device 2>/dev/null || true
        ROOT_UID=$(adb shell id -u 2>/dev/null | strip_cr || echo "unknown")
        if [ "$ROOT_UID" = "0" ]; then
            log "adb root: ACTIVE (adbd running as UID 0)"
            USE_ADB_ROOT=true
            USE_SU=false
            return 0
        fi
    fi

    # Fallback to su
    SU_CHECK=$(adb shell "which su" 2>/dev/null | strip_cr)
    if [ -n "$SU_CHECK" ]; then
        SU_UID=$(adb shell "su 0 id -u" 2>/dev/null | strip_cr || echo "unknown")
        if [ "$SU_UID" = "0" ]; then
            log "su binary: ACTIVE (KernelSU / Magisk root verified)"
            USE_ADB_ROOT=false
            USE_SU=true
            return 0
        fi
    fi

    warn "Running in NON-ROOT mode. Kernel dmesg / pstore / data tombstones may be limited."
    USE_ADB_ROOT=false
    USE_SU=false
}

adb_cmd() {
    local cmd="$*"
    if [ "$USE_ADB_ROOT" = true ]; then
        timeout "$TIMEOUT_SEC" adb shell "$cmd" 2>/dev/null | strip_cr || true
    elif [ "$USE_SU" = true ]; then
        timeout "$TIMEOUT_SEC" adb shell "su 0 sh -c '$cmd'" 2>/dev/null | strip_cr || true
    else
        timeout "$TIMEOUT_SEC" adb shell "$cmd" 2>/dev/null | strip_cr || true
    fi
}

adb_cmd_raw() {
    local cmd="$*"
    if [ "$USE_ADB_ROOT" = true ]; then
        timeout "$TIMEOUT_SEC" adb shell "$cmd" 2>/dev/null || true
    elif [ "$USE_SU" = true ]; then
        timeout "$TIMEOUT_SEC" adb shell "su 0 sh -c '$cmd'" 2>/dev/null || true
    else
        timeout "$TIMEOUT_SEC" adb shell "$cmd" 2>/dev/null || true
    fi
}

log_filtered_dmesg() {
    local pattern="$1"
    local outfile="$2"
    if [ ! -f "$OUTPUT_DIR/kernel/dmesg.txt" ] || [ ! -s "$OUTPUT_DIR/kernel/dmesg.txt" ]; then
        echo "# dmesg not captured or empty" > "$outfile"
        return 0
    fi
    grep -iE "$pattern" "$OUTPUT_DIR/kernel/dmesg.txt" > "$outfile" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════
# LIVE MONITOR MODE
# ════════════════════════════════════════════════════════════════
run_monitor_mode() {
    title "Live Crash Streaming Monitor"
    mkdir -p "$OUTPUT_DIR"/{live,kernel,logcat}
    
    echo -e "${YELLOW}Starting real-time streaming to host PC...${NC}"
    echo "  → Logcat : $OUTPUT_DIR/live/live_logcat.txt"
    echo "  → Dmesg  : $OUTPUT_DIR/live/live_dmesg.txt"

    adb logcat -v time -b all > "$OUTPUT_DIR/live/live_logcat.txt" 2>&1 &
    LOGCAT_PID=$!

    DMESG_PID=""
    if [ "$USE_ADB_ROOT" = true ]; then
        adb shell "dmesg -w" > "$OUTPUT_DIR/live/live_dmesg.txt" 2>&1 &
        DMESG_PID=$!
    elif [ "$USE_SU" = true ]; then
        adb shell "su 0 sh -c 'dmesg -w'" > "$OUTPUT_DIR/live/live_dmesg.txt" 2>&1 &
        DMESG_PID=$!
    fi

    echo ""
    echo -e "${BOLD}${CYAN}==============================================================${NC}"
    echo -e "${BOLD}${GREEN}  >>> READY! NOW UNLOCK YOUR PHONE / TRIGGER THE CRASH <<<${NC}"
    echo -e "  Press Ctrl+C when reboot occurs or testing is complete."
    echo -e "${BOLD}${CYAN}==============================================================${NC}"
    echo ""

    monitor_cleanup() {
        echo ""
        log "Stopping background monitors..."
        kill "$LOGCAT_PID" 2>/dev/null || true
        [ -n "$DMESG_PID" ] && kill "$DMESG_PID" 2>/dev/null || true

        log "Analyzing captured stream..."
        grep -iE 'fatal|panic|oops|backtrace|abort|sigsegv|sigabrt|died' "$OUTPUT_DIR/live/live_logcat.txt" \
            > "$OUTPUT_DIR/live/logcat_crash_summary.txt" 2>/dev/null || true
        if [ -f "$OUTPUT_DIR/live/live_dmesg.txt" ]; then
            grep -iE 'panic|oops|bug:|fatal|call trace|cut here' "$OUTPUT_DIR/live/live_dmesg.txt" \
                > "$OUTPUT_DIR/live/dmesg_panic_summary.txt" 2>/dev/null || true
        fi

        compress_output
        print_summary
        triage_report
        exit 0
    }
    trap monitor_cleanup INT TERM

    while true; do
        if ! adb devices 2>/dev/null | grep -q "device$"; then
            warn "Device reboot/disconnect detected!"
            sleep 2
            monitor_cleanup
        fi
        sleep 1
    done
}

# ════════════════════════════════════════════════════════════════
# SETUP BASELINE MODE
# ════════════════════════════════════════════════════════════════
run_setup_baseline() {
    title "Capturing Baseline State"
    mkdir -p "$OUTPUT_DIR"/baseline
    adb_cmd "logpersist.start" || true
    adb_cmd "echo 1 > /proc/sys/kernel/printk_devkmsg" || true
    adb shell "logcat -G 16M" 2>/dev/null || true

    adb_cmd "uname -a"          > "$OUTPUT_DIR/baseline/kernel.txt"
    adb_cmd "cat /proc/cmdline" > "$OUTPUT_DIR/baseline/cmdline.txt"
    adb_cmd "getenforce"        > "$OUTPUT_DIR/baseline/selinux.txt"
    adb_cmd "dmesg"             > "$OUTPUT_DIR/baseline/dmesg.txt"
    adb logcat -d -b all        > "$OUTPUT_DIR/baseline/logcat.txt" 2>/dev/null || true

    log "Baseline saved to $OUTPUT_DIR/baseline/"
    log "Ready to flash test kernel."
    exit 0
}

# ════════════════════════════════════════════════════════════════
# STANDARD COLLECTION MODULES
# ════════════════════════════════════════════════════════════════
setup_directories() {
    title "Environment Setup"
    check_adb
    gain_root

    mkdir -p "$OUTPUT_DIR"/{kernel,logcat,qcom,pstore,anr,tombstones,\
thermal,memory,power,boot,perf,radio,system,selinux,hal,binder}

    adb_cmd "mkdir -p $DEVICE_TMP" || true

    {
        echo "=== Capture Metadata ==="
        echo "Timestamp  : $(date)"
        echo "Mode       : $MODE"
        echo "Codename   : $DEVICE_CODENAME"
        echo "SoC        : $SOC"
        echo "ROM        : $ROM"
        echo "Build ID   : $(adb shell getprop ro.build.display.id 2>/dev/null | strip_cr)"
        echo "Android    : $(adb shell getprop ro.build.version.release 2>/dev/null | strip_cr)"
        echo "Kernel     : $(adb shell uname -r 2>/dev/null | strip_cr)"
        echo "Uptime     : $(adb shell uptime 2>/dev/null | strip_cr)"
        echo "Slot       : $(adb shell getprop ro.boot.slot_suffix 2>/dev/null | strip_cr)"
        echo "Root Mode  : $( [ "$USE_ADB_ROOT" = true ] && echo 'adb root' || ([ "$USE_SU" = true ] && echo 'su binary' || echo 'non-root') )"
    } > "$OUTPUT_DIR/capture_info.txt"

    log "Target: $OUTPUT_DIR | Mode: $MODE"
}

collect_kernel_logs() {
    title "Kernel Logs & Pstore"

    log "Capturing dmesg..."
    adb_cmd "dmesg" > "$OUTPUT_DIR/kernel/dmesg.txt"
    adb_cmd "dmesg -T" > "$OUTPUT_DIR/kernel/dmesg_timestamped.txt"

    log_filtered_dmesg "error|fault|panic|oops|bug|fail|warn|null pointer" "$OUTPUT_DIR/kernel/dmesg_errors.txt"
    log_filtered_dmesg "panic|oops|bug:|fatal|call trace|cut here"        "$OUTPUT_DIR/kernel/dmesg_panics.txt"
    log_filtered_dmesg "sde|dsi|drm|display|panel|mdss|composer|hwc"     "$OUTPUT_DIR/kernel/dmesg_display.txt"
    log_filtered_dmesg "fingerprint|silead|fpc|goodix|synna"             "$OUTPUT_DIR/kernel/dmesg_fingerprint.txt"
    log_filtered_dmesg "avc:.*denied"                                    "$OUTPUT_DIR/kernel/dmesg_avc_denials.txt"
    log_filtered_dmesg "qcom|msm|sm6375|kryo|adreno|kgsl"                "$OUTPUT_DIR/kernel/dmesg_qcom.txt"

    log "Capturing pstore / ramoops..."
    PSTORE_LIST=$(adb_cmd "ls /sys/fs/pstore/ 2>/dev/null" | strip_cr | grep -v '^$')
    if [ -n "$PSTORE_LIST" ]; then
        for f in console-ramoops-0 dmesg-ramoops-0 pmsg-ramoops-0 console-ramdump-0 dmesg-ramdump-0; do
            adb_cmd "cat /sys/fs/pstore/$f 2>/dev/null" > "$OUTPUT_DIR/pstore/${f}.txt" || true
        done
        echo "$PSTORE_LIST" | while IFS= read -r pf; do
            [ -z "$pf" ] && continue
            adb_cmd "cat /sys/fs/pstore/$pf 2>/dev/null" > "$OUTPUT_DIR/pstore/${pf}.txt" || true
        done
    else
        warn "pstore directory empty or inaccessible."
    fi

    adb_cmd "cat /proc/last_kmsg 2>/dev/null"   > "$OUTPUT_DIR/kernel/last_kmsg.txt" || true
    adb_cmd "cat /proc/version"                > "$OUTPUT_DIR/kernel/version.txt"
    adb_cmd "cat /proc/cmdline"                > "$OUTPUT_DIR/kernel/cmdline.txt"
    adb_cmd "zcat /proc/config.gz 2>/dev/null" > "$OUTPUT_DIR/kernel/running_config.txt" || true
    adb_cmd "lsmod"                            > "$OUTPUT_DIR/kernel/lsmod.txt" || true
}

collect_logcat() {
    title "Logcat Buffers"

    adb logcat -b all -d          > "$OUTPUT_DIR/logcat/logcat_all.txt"    2>/dev/null || true
    adb logcat -b main -d *:E     > "$OUTPUT_DIR/logcat/logcat_errors.txt" 2>/dev/null || true
    adb logcat -b crash -d        > "$OUTPUT_DIR/logcat/logcat_crash.txt"  2>/dev/null || true
    adb logcat -b system -d       > "$OUTPUT_DIR/logcat/logcat_system.txt" 2>/dev/null || true
    adb logcat -b radio -d        > "$OUTPUT_DIR/logcat/logcat_radio.txt"  2>/dev/null || true
    log "Logcat buffers dumped."
}

collect_crash_forensics() {
    title "Crash Forensics (Tombstones, ANRs & Dropbox)"

    # Tombstones
    RAW_COUNT=$(adb_cmd "ls /data/tombstones/ 2>/dev/null | wc -l" | tr -d ' ')
    if [[ "$RAW_COUNT" =~ ^[0-9]+$ ]] && [ "$RAW_COUNT" -gt 0 ]; then
        log "Found $RAW_COUNT tombstone(s) — pulling..."
        if ! adb pull /data/tombstones/ "$OUTPUT_DIR/tombstones/" 2>/dev/null; then
            warn "Direct tombstone pull restricted — relaying via sdcard..."
            adb_cmd "cp -r /data/tombstones/ $DEVICE_TMP/ 2>/dev/null" || true
            adb pull "$DEVICE_TMP/tombstones" "$OUTPUT_DIR/tombstones/" 2>/dev/null || true
        fi
    fi

    # ANRs
    adb_cmd "cp -r /data/anr/ $DEVICE_TMP/anr 2>/dev/null" || true
    adb pull "$DEVICE_TMP/anr" "$OUTPUT_DIR/anr/" 2>/dev/null || true

    # Dropbox dumpsys (fast targeted parsing)
    log "Extracting Dropbox crash entries..."
    adb shell "dumpsys dropbox --print system_server_crash" > "$OUTPUT_DIR/system/dropbox_system_server_crash.txt" 2>/dev/null || true
    adb shell "dumpsys dropbox --print system_server_wtf"   > "$OUTPUT_DIR/system/dropbox_system_server_wtf.txt" 2>/dev/null || true
    adb shell "dumpsys dropbox --print system_app_crash"    > "$OUTPUT_DIR/system/dropbox_system_app_crash.txt" 2>/dev/null || true
    adb shell "dumpsys dropbox --print SYSTEM_TOMBSTONE"    > "$OUTPUT_DIR/system/dropbox_tombstone.txt" 2>/dev/null || true
}

collect_binder_ipc() {
    title "Binder IPC Debugging"
    log "Capturing Binder transaction logs..."
    adb_cmd "cat /sys/kernel/debug/binder/failed_transaction_log 2>/dev/null" > "$OUTPUT_DIR/binder/failed_transactions.txt" || true
    adb_cmd "cat /sys/kernel/debug/binder/transaction_log 2>/dev/null"        > "$OUTPUT_DIR/binder/transactions.txt" || true
    adb_cmd "cat /sys/kernel/debug/binder/state 2>/dev/null"                  > "$OUTPUT_DIR/binder/state.txt" || true
    adb_cmd "cat /sys/kernel/debug/binder/stats 2>/dev/null"                  > "$OUTPUT_DIR/binder/stats.txt" || true
}

collect_qcom_logs() {
    title "QCOM SM6375 Hardware Profiling"

    adb_cmd "mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs none /sys/kernel/debug 2>/dev/null" || true

    adb_cmd "cat /sys/kernel/debug/clk/clk_summary 2>/dev/null"             > "$OUTPUT_DIR/qcom/clk_summary.txt" || true
    adb_cmd "cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null" > "$OUTPUT_DIR/qcom/regulator_summary.txt" || true
    adb_cmd "cat /sys/kernel/debug/rpm_stats 2>/dev/null"                   > "$OUTPUT_DIR/qcom/rpm_stats.txt" || true
    adb_cmd "cat /sys/kernel/debug/rpm_master_stats 2>/dev/null"            > "$OUTPUT_DIR/qcom/rpm_master_stats.txt" || true
    adb_cmd "cat /sys/kernel/debug/ion/heaps 2>/dev/null"                   > "$OUTPUT_DIR/qcom/ion_heaps.txt" || true

    # CPU Freq state (single loop)
    log "Capturing 8-core CPU frequency scaling..."
    adb_cmd '
        for cpu in 0 1 2 3 4 5 6 7; do
            CP="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
            echo "=== CPU${cpu} ==="
            echo "Cur: $(cat ${CP}/scaling_cur_freq 2>/dev/null || echo offline)"
            echo "Gov: $(cat ${CP}/scaling_governor 2>/dev/null || echo N/A)"
            echo "Max: $(cat ${CP}/scaling_max_freq 2>/dev/null || echo N/A)"
        done
    ' > "$OUTPUT_DIR/qcom/cpufreq_all.txt"

    # Adreno 619L
    log "Capturing Adreno 619L GPU state..."
    KGSL="/sys/class/kgsl/kgsl-3d0"
    {
        echo "=== Adreno 619L ==="
        echo "Freq Hz  : $(adb_cmd "cat ${KGSL}/gpuclk 2>/dev/null")"
        echo "Busy %   : $(adb_cmd "cat ${KGSL}/gpu_busy_percentage 2>/dev/null")"
        echo "MinMHz   : $(adb_cmd "cat ${KGSL}/min_clock_mhz 2>/dev/null")"
        echo "MaxMHz   : $(adb_cmd "cat ${KGSL}/max_clock_mhz 2>/dev/null")"
        echo "PwrLevel : $(adb_cmd "cat ${KGSL}/pwrlevel 2>/dev/null")"
        echo "State    : $(adb_cmd "cat ${KGSL}/state 2>/dev/null")"
    } > "$OUTPUT_DIR/qcom/gpu_adreno619l.txt"

    log_filtered_dmesg "wcn|wlan|ath|qca"              "$OUTPUT_DIR/qcom/wlan_dmesg.txt"
    log_filtered_dmesg "modem|ipa|rmnet|qrtr|smd|glink" "$OUTPUT_DIR/qcom/modem_dmesg.txt"
}

collect_thermal_logs() {
    title "Thermal Zones (On-Device Batch)"

    adb_cmd '
        printf "%-10s | %-40s | %s\n" "Zone" "Type" "Temp(mC)"
        printf "%s\n" "--------------------------------------------------------------"
        for zone in /sys/class/thermal/thermal_zone*; do
            zname=$(basename "$zone")
            ztype=$(cat "$zone/type" 2>/dev/null || echo "unknown")
            ztemp=$(cat "$zone/temp" 2>/dev/null || echo "N/A")
            printf "%-10s | %-40s | %s\n" "$zname" "$ztype" "$ztemp"
        done
    ' > "$OUTPUT_DIR/thermal/thermal_zones.txt"

    adb_cmd "dumpsys thermalservice 2>/dev/null"           > "$OUTPUT_DIR/thermal/thermalservice.txt" || true
    adb_cmd "cat /sys/class/power_supply/battery/temp 2>/dev/null" > "$OUTPUT_DIR/thermal/battery_temp.txt" || true
}

collect_selinux_logs() {
    title "SELinux Status & Audits"

    adb_cmd "getenforce" > "$OUTPUT_DIR/selinux/mode.txt" || true
    log_filtered_dmesg "avc|selinux|denied" "$OUTPUT_DIR/selinux/avc_dmesg.txt"
    adb logcat -b all -d 2>/dev/null | grep -iE "avc|selinux|denied" > "$OUTPUT_DIR/selinux/avc_logcat.txt" || true
}

# ── KernelSU / root-manager forensics (targets soft-reboot cause list) ────────
# Covers: spoofed-manager RCU (-24), stale metamodule flag, BPF map limit,
#         audio.service SIGSEGV tombstone, KSU supercall return code.
collect_ksu_forensics() {
    title "KernelSU / Root-Manager Forensics"

    mkdir -p "$OUTPUT_DIR/ksu"

    # 1. Installed KSU managers (spoofed vs official detection)
    adb_cmd "pm list packages 2>/dev/null | grep -iE 'kernelsu|ksu'" \
        > "$OUTPUT_DIR/ksu/manager_packages.txt" || true

    # 2. KSU version from kernel
    adb_cmd "cat /proc/version" > "$OUTPUT_DIR/ksu/kernel_version.txt" || true
    adb_cmd "cat /data/adb/ksu/.version 2>/dev/null" > "$OUTPUT_DIR/ksu/ksu_version.txt" || true

    # 3. Metamodule / module state flags (Cause #3: stale update flag)
    adb_cmd "ls -la /data/adb/modules/ 2>/dev/null" > "$OUTPUT_DIR/ksu/modules_dir.txt" || true
    adb_cmd "ls -la /data/adb/metamodule 2>/dev/null" > "$OUTPUT_DIR/ksu/metamodule_symlink.txt" || true
    adb_cmd "for d in /data/adb/modules/*/; do echo \"== \$d ==\"; ls -la \"\$d\" 2>/dev/null | grep -iE 'update|install|remove|disable'; cat \"\$d/module.prop\" 2>/dev/null | grep -i metamodule; done" \
        > "$OUTPUT_DIR/ksu/module_flags.txt" || true

    # 4. KSU internal state
    adb_cmd "ls -la /data/adb/ksu/ 2>/dev/null" > "$OUTPUT_DIR/ksu/ksu_state.txt" || true

    # 5. BPF map limit (Cause #5: EMFILE -24 on bpf map swap)
    adb_cmd "cat /proc/sys/fs/maxfiles 2>/dev/null" > "$OUTPUT_DIR/ksu/maxfiles.txt" || true
    adb_cmd "cat /proc/sys/fs/nr_open 2>/dev/null" > "$OUTPUT_DIR/ksu/nr_open.txt" || true
    adb_cmd "ls /sys/fs/bpf/ 2>/dev/null | wc -l" > "$OUTPUT_DIR/ksu/bpf_map_count.txt" || true
    adb_cmd "cat /proc/buddyinfo 2>/dev/null | head -3" > "$OUTPUT_DIR/ksu/buddyinfo.txt" || true

    # 6. RCU cmdline + stall check (Cause #4 / #10)
    adb_cmd "cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -i rcu" > "$OUTPUT_DIR/ksu/rcu_cmdline.txt" || true
    adb_cmd "dmesg 2>/dev/null | grep -iE 'rcu.*stall|rcu.*expedited' | tail -5" > "$OUTPUT_DIR/ksu/rcu_dmesg.txt" || true

    # 7. audio.service tombstone (Cause #6: SIGSEGV cascade) — pull latest
    adb_cmd "ls -t /data/tombstones/ 2>/dev/null | head -1" > "$OUTPUT_DIR/ksu/latest_tombstone.txt" || true
    local ts=$(adb_cmd "ls -t /data/tombstones/ 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
    if [ -n "$ts" ]; then
        adb_cmd "cat /data/tombstones/$ts 2>/dev/null | head -60" > "$OUTPUT_DIR/ksu/tombstone_audio.txt" || true
    fi

    # 8. KSU supercall return trace (Cause #10) — grep kernel log for ksu errors
    log_filtered_dmesg "ksu|kernelsu|supercall|synchronizeKernelRCU" "$OUTPUT_DIR/ksu/ksu_dmesg.txt"
}

collect_hal_logs() {
    title "HAL & Display Subsystem"

    adb_cmd "dumpsys display"       > "$OUTPUT_DIR/hal/display.txt" || true
    adb_cmd "dumpsys SurfaceFlinger" > "$OUTPUT_DIR/hal/surfaceflinger.txt" || true
    adb_cmd "dumpsys input"         > "$OUTPUT_DIR/hal/input.txt" || true
    adb_cmd "dumpsys fingerprint"   > "$OUTPUT_DIR/hal/fingerprint.txt" || true
    adb_cmd "dumpsys biometric"     > "$OUTPUT_DIR/hal/biometric.txt" || true
    adb_cmd "dumpsys audio"         > "$OUTPUT_DIR/hal/audio.txt" || true
    adb_cmd "dumpsys media.camera"  > "$OUTPUT_DIR/hal/camera.txt" || true
    adb_cmd "dumpsys sensorservice" > "$OUTPUT_DIR/hal/sensors.txt" || true
    adb_cmd "dumpsys power"         > "$OUTPUT_DIR/hal/power.txt" || true
    adb_cmd "dumpsys window"        > "$OUTPUT_DIR/hal/window.txt" || true

    log_filtered_dmesg "audio|sound|msm-dai|q6afe|slimbus" "$OUTPUT_DIR/hal/audio_dmesg.txt"
    log_filtered_dmesg "camera|csid|csiphy|vfe|cpp|cci"    "$OUTPUT_DIR/hal/camera_dmesg.txt"
    log_filtered_dmesg "drm|mdss|dsi|panel"                 "$OUTPUT_DIR/hal/display_dmesg.txt"
}

collect_system_state() {
    title "System State"

    adb_cmd "cat /proc/meminfo"  > "$OUTPUT_DIR/memory/meminfo.txt" || true
    adb_cmd "cat /proc/vmstat"   > "$OUTPUT_DIR/memory/vmstat.txt" || true
    adb_cmd "dumpsys meminfo"    > "$OUTPUT_DIR/memory/dumpsys_meminfo.txt" || true
    adb_cmd "dumpsys cpuinfo"    > "$OUTPUT_DIR/system/cpuinfo.txt" || true
    adb_cmd "getprop"           > "$OUTPUT_DIR/system/getprop.txt" || true
    adb_cmd "df -h"             > "$OUTPUT_DIR/system/disk.txt" || true
    adb_cmd "ps -A"             > "$OUTPUT_DIR/system/ps.txt" || true
    adb_cmd "cat /proc/mounts"  > "$OUTPUT_DIR/system/mounts.txt" || true
}

cleanup_device() {
    adb_cmd "rm -rf $DEVICE_TMP" 2>/dev/null || true
}

compress_output() {
    title "Archive Creation"
    ARCHIVE="veux_logs_${TIMESTAMP}.tar.gz"
    if tar -czf "$ARCHIVE" "$OUTPUT_DIR/" 2>/dev/null; then
        ARCHIVE_SIZE=$(du -sh "$ARCHIVE" 2>/dev/null | awk '{print $1}')
        log "Compressed bundle: $ARCHIVE ($ARCHIVE_SIZE)"
    else
        warn "Tar compression failed. Raw logs available in: $OUTPUT_DIR/"
    fi
}

print_summary() {
    title "Collection Summary"
    echo ""
    find "$OUTPUT_DIR" -type f | sort | while IFS= read -r f; do
        SIZE=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
        if [ "$SIZE" -gt 50 ] 2>/dev/null; then
            RELPATH="${f#"$OUTPUT_DIR/"}"
            FSIZE=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
            printf "  %-55s %s\n" "$RELPATH" "$FSIZE"
        fi
    done
    echo ""
    TOTAL=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
    log "Total directory size: ${TOTAL:-unknown}"
}

triage_report() {
    title "Automated Root-Cause Triage"
    echo ""
    local found=0

    if [ -s "$OUTPUT_DIR/kernel/dmesg_panics.txt" ]; then
        echo -e "${RED}${BOLD}🔴 [CRITICAL] Kernel Panic / Oops detected in dmesg:${NC}"
        head -5 "$OUTPUT_DIR/kernel/dmesg_panics.txt"
        echo ""
        found=1
    fi

    if [ -s "$OUTPUT_DIR/system/dropbox_system_server_crash.txt" ]; then
        echo -e "${RED}${BOLD}🔴 [CRITICAL] system_server crash logged in Dropbox:${NC}"
        grep -E 'Process:|Flags:|Subject:|FATAL EXCEPTION|Abort message' "$OUTPUT_DIR/system/dropbox_system_server_crash.txt" | head -6
        echo ""
        found=1
    fi

    if [ -s "$OUTPUT_DIR/pstore/console-ramoops-0.txt" ] || [ -s "$OUTPUT_DIR/pstore/console-ramdump-0.txt" ]; then
        echo -e "${YELLOW}${BOLD}🟡 [WARNING] Prior crash dump present in pstore:${NC}"
        head -5 "$OUTPUT_DIR/pstore/"console-ram*.txt 2>/dev/null | head -5
        echo ""
        found=1
    fi

    if [ -s "$OUTPUT_DIR/binder/failed_transactions.txt" ]; then
        echo -e "${YELLOW}${BOLD}🟡 [WARNING] Binder failed transactions detected:${NC}"
        head -5 "$OUTPUT_DIR/binder/failed_transactions.txt"
        echo ""
        found=1
    fi

    if [ -s "$OUTPUT_DIR/logcat/logcat_crash.txt" ]; then
        echo -e "${YELLOW}${BOLD}🟡 [WARNING] Crash buffer entries in logcat:${NC}"
        head -6 "$OUTPUT_DIR/logcat/logcat_crash.txt"
        echo ""
        found=1
    fi

    if [ "$found" -eq 0 ]; then
        log "No obvious kernel panics or FATAL exceptions found in standard filters."
        info "Inspect raw files in $OUTPUT_DIR/ for subtle race conditions or HAL timeouts."
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════════
# MAIN ROUTING
# ════════════════════════════════════════════════════════════════
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  veux Master Diagnostic Collector v2.0 (Hardened)   ║"
    echo "║  SoC: SM6375 (SD695) | Target: PixelOS Android 16/17 ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    case "$MODE" in
        monitor|live)
            check_adb
            gain_root
            run_monitor_mode
            ;;
        setup)
            check_adb
            gain_root
            run_setup_baseline
            ;;
        boot)
            setup_directories
            collect_kernel_logs
            collect_logcat
            collect_selinux_logs
            collect_system_state
            ;;
        crash)
            setup_directories
            collect_kernel_logs
            collect_logcat
            collect_crash_forensics
            collect_binder_ipc
            collect_selinux_logs
            collect_ksu_forensics
            collect_hal_logs
            ;;
        perf)
            setup_directories
            collect_kernel_logs
            collect_thermal_logs
            collect_qcom_logs
            collect_system_state
            ;;
        quick)
            setup_directories
            collect_kernel_logs
            collect_logcat
            collect_system_state
            ;;
        ksu)
            check_adb
            gain_root
            setup_directories
            collect_ksu_forensics
            ;;
        full|*)
            setup_directories
            collect_kernel_logs
            collect_logcat
            collect_crash_forensics
            collect_binder_ipc
            collect_qcom_logs
            collect_thermal_logs
            collect_selinux_logs
            collect_ksu_forensics
            collect_hal_logs
            collect_system_state
            ;;
    esac

    cleanup_device
    compress_output
    print_summary
    triage_report

    log "Done → ${OUTPUT_DIR}/"
}

main "$@"
