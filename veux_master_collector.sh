#!/bin/bash
# ================================================
# veux_master_collector.sh — AUDITED v1.1
# Fixed: C1, C2, C3, C4, M1, M2, M3, M4, M5
#        N1, N2, N3, N4
# ================================================

# ── FIX C1: Remove set -e, use explicit error handling ──
# set -e removed entirely — log collection must be resilient,
# not stop on first non-zero exit code
set -uo pipefail

# ── Config ──────────────────────────────────────
DEVICE_CODENAME="veux"
SOC="SM6375"
ROM="PixelOS"
MODE="${1:-full}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="./veux_logs_${TIMESTAMP}"
DEVICE_TMP="/sdcard/veux_debug_tmp"
USE_SU=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }
title() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# ── FIX M1: ADB output CRLF stripper ────────────
strip_cr() {
    tr -d '\r'
}

check_adb() {
    if ! command -v adb &>/dev/null; then
        error "adb not found. Install platform-tools first."
        exit 1
    fi
    if ! adb devices | grep -q "device$"; then
        error "No device detected. Check USB connection & ADB auth."
        exit 1
    fi
    log "Device connected: $(adb devices | grep 'device$' | awk '{print $1}')"
}

# ── FIX C1: gain_root — no longer exits on failure ──
gain_root() {
    title "Gaining Root Access (PixelOS userdebug)"

    if adb root 2>/dev/null; then
        sleep 2
        adb wait-for-device 2>/dev/null || true
        ROOT_CHECK=$(adb shell whoami 2>/dev/null | strip_cr)
        if [ "$ROOT_CHECK" = "root" ]; then
            log "adb root: SUCCESS (userdebug build confirmed)"
            USE_SU=false
        else
            warn "adb root ran but shell is not root — trying Magisk su"
            USE_SU=true
        fi
    else
        warn "adb root failed — falling back to Magisk su"
        USE_SU=true
    fi

    adb remount 2>/dev/null || true
}

# ── adb_cmd wrapper ──────────────────────────────
adb_cmd() {
    local output
    if [ "$USE_SU" = true ]; then
        output=$(adb shell su -c "$*" 2>/dev/null | strip_cr)
    else
        output=$(adb shell "$*" 2>/dev/null | strip_cr)
    fi
    echo "$output"
}

# ── FIX C2 + M5: Safe dmesg grep ────────────────
log_filtered_dmesg() {
    local pattern="$1"
    local outfile="$2"
    if [ ! -f "$OUTPUT_DIR/kernel/dmesg.txt" ]; then
        warn "dmesg.txt not yet captured — skipping filter for: $pattern"
        echo "# dmesg not captured when this filter ran" > "$outfile"
        return 0
    fi
    grep -iE "$pattern" "$OUTPUT_DIR/kernel/dmesg.txt" \
        > "$outfile" 2>/dev/null || true
}

setup() {
    title "Setup"
    check_adb
    gain_root

    mkdir -p "$OUTPUT_DIR"/{kernel,logcat,qcom,pstore,anr,tombstones,\
thermal,memory,power,boot,perf,radio,system,selinux,hal}

    adb_cmd "mkdir -p $DEVICE_TMP" || true

    {
        echo "=== Capture Info ==="
        echo "Date       : $(date)"
        echo "Mode       : $MODE"
        echo "Codename   : $DEVICE_CODENAME"
        echo "SoC        : $SOC"
        echo "ROM        : $ROM"
        echo "Build      : $(adb shell getprop ro.build.description 2>/dev/null | strip_cr)"
        echo "Android    : $(adb shell getprop ro.build.version.release 2>/dev/null | strip_cr)"
        echo "Kernel     : $(adb shell uname -r 2>/dev/null | strip_cr)"
        echo "Uptime     : $(adb shell uptime 2>/dev/null | strip_cr)"
        echo "adb root   : $( [ "$USE_SU" = true ] && echo 'Magisk su' || echo 'adb root')"
    } > "$OUTPUT_DIR/capture_info.txt"

    log "Output: $OUTPUT_DIR | Mode: $MODE"
}

collect_kernel_logs() {
    title "Kernel Logs"

    log "Capturing dmesg..."
    adb_cmd "dmesg" > "$OUTPUT_DIR/kernel/dmesg.txt"
    adb_cmd "dmesg -T" > "$OUTPUT_DIR/kernel/dmesg_timestamped.txt"

    grep -iE "error|fault|panic|oops|bug|fail|warn" \
        "$OUTPUT_DIR/kernel/dmesg.txt" \
        > "$OUTPUT_DIR/kernel/dmesg_errors_only.txt" 2>/dev/null || true

    grep -iE "qcom|msm|sm6375|kryo|adreno|kgsl" \
        "$OUTPUT_DIR/kernel/dmesg.txt" \
        > "$OUTPUT_DIR/kernel/dmesg_qcom_only.txt" 2>/dev/null || true

    log "Capturing pstore..."
    PSTORE_LIST=$(adb_cmd "ls /sys/fs/pstore/ 2>/dev/null" | strip_cr | grep -v '^$')

    if [ -n "$PSTORE_LIST" ]; then
        for f in console-ramoops-0 dmesg-ramoops-0 pmsg-ramoops-0; do
            adb_cmd "cat /sys/fs/pstore/$f 2>/dev/null" \
                > "$OUTPUT_DIR/pstore/${f}.txt" \
                && log "  ✓ $f" \
                || warn "  ✗ $f"
        done

        echo "$PSTORE_LIST" | while IFS= read -r pf; do
            [ -z "$pf" ] && continue
            [[ "$pf" == console-ramoops-0 ]] && continue
            [[ "$pf" == dmesg-ramoops-0 ]]   && continue
            [[ "$pf" == pmsg-ramoops-0 ]]     && continue

            adb_cmd "cat /sys/fs/pstore/$pf 2>/dev/null" \
                > "$OUTPUT_DIR/pstore/${pf}.txt" 2>/dev/null || true
        done
    else
        warn "pstore empty — verify CONFIG_PSTORE_RAM=y in kernel defconfig"
    fi

    adb_cmd "cat /proc/last_kmsg 2>/dev/null" \
        > "$OUTPUT_DIR/kernel/last_kmsg.txt" 2>/dev/null || true

    adb_cmd "cat /proc/version"  > "$OUTPUT_DIR/kernel/version.txt"
    adb_cmd "cat /proc/cmdline" > "$OUTPUT_DIR/kernel/cmdline.txt"
    adb_cmd "zcat /proc/config.gz 2>/dev/null" \
        > "$OUTPUT_DIR/kernel/kernel_config.txt" 2>/dev/null || true
}

collect_logcat() {
    title "Logcat"

    adb logcat -b all -d \
        > "$OUTPUT_DIR/logcat/logcat_all.txt"      2>/dev/null || true
    adb logcat -b main -d *:E \
        > "$OUTPUT_DIR/logcat/logcat_errors.txt"   2>/dev/null || true
    adb logcat -b crash -d \
        > "$OUTPUT_DIR/logcat/logcat_crash.txt"    2>/dev/null || true
    adb logcat -b system -d \
        > "$OUTPUT_DIR/logcat/logcat_system.txt"   2>/dev/null || true
    adb logcat -b kernel -d \
        > "$OUTPUT_DIR/logcat/logcat_kernel.txt"   2>/dev/null || true
    adb logcat -b radio -d \
        > "$OUTPUT_DIR/logcat/logcat_radio.txt"    2>/dev/null || true

    log "Logcat buffers captured"
}

collect_qcom_logs() {
    title "QCOM SM6375 Specific"

    adb_cmd "mountpoint -q /sys/kernel/debug 2>/dev/null \
        || mount -t debugfs none /sys/kernel/debug 2>/dev/null" \
        || warn "debugfs mount failed — some QCOM logs may be missing"

    adb_cmd "cat /sys/kernel/debug/clk/clk_summary 2>/dev/null" \
        > "$OUTPUT_DIR/qcom/clk_summary.txt"       || true
    adb_cmd "cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null" \
        > "$OUTPUT_DIR/qcom/regulator_summary.txt" || true
    adb_cmd "cat /sys/kernel/debug/rpm_stats 2>/dev/null" \
        > "$OUTPUT_DIR/qcom/rpm_stats.txt"         || true
    adb_cmd "cat /sys/kernel/debug/rpm_master_stats 2>/dev/null" \
        > "$OUTPUT_DIR/qcom/rpm_master_stats.txt"  || true

    log "Capturing CPU frequency states..."
    {
        for cpu in 0 1 2 3 4 5 6 7; do
            CPU_PATH="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
            echo "=== CPU${cpu} ==="
            adb_cmd "cat ${CPU_PATH}/scaling_cur_freq 2>/dev/null" || echo "offline"
            adb_cmd "cat ${CPU_PATH}/scaling_governor 2>/dev/null" || echo "N/A"
            adb_cmd "cat ${CPU_PATH}/scaling_max_freq 2>/dev/null" || echo "N/A"
        done
    } > "$OUTPUT_DIR/qcom/cpufreq_all.txt"

    log "Capturing Adreno 619L state..."
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

    adb_cmd "cat /sys/kernel/debug/ion/heaps 2>/dev/null" \
        > "$OUTPUT_DIR/qcom/ion_heaps.txt" || true

    log "QCOM logs done"
}

collect_thermal_logs() {
    title "Thermal (SM6375)"

    log "Capturing all thermal zones (single adb call)..."
    adb_cmd '
        printf "%-10s | %-40s | %s\n" "Zone" "Type" "Temp(raw)"
        printf "%s\n" "--------------------------------------------------------------"
        for zone in /sys/class/thermal/thermal_zone*; do
            zname=$(basename "$zone")
            ztype=$(cat "$zone/type"  2>/dev/null || echo "unknown")
            ztemp=$(cat "$zone/temp"  2>/dev/null || echo "N/A")
            printf "%-10s | %-40s | %s\n" "$zname" "$ztype" "$ztemp"
        done
    ' > "$OUTPUT_DIR/thermal/thermal_zones.txt"

    echo "# NOTE: Temp column = raw kernel value (millidegrees Celsius)" \
        >> "$OUTPUT_DIR/thermal/thermal_zones.txt"
    echo "# Divide by 1000 to get °C  (e.g. 35000 = 35.0°C)" \
        >> "$OUTPUT_DIR/thermal/thermal_zones.txt"

    adb_cmd "dumpsys thermalservice" \
        > "$OUTPUT_DIR/thermal/thermalservice_dump.txt" || true
    adb_cmd "cat /sys/class/power_supply/battery/temp 2>/dev/null" \
        > "$OUTPUT_DIR/thermal/battery_temp.txt" || true
}

collect_crash_logs() {
    title "Crash (Tombstones + ANR)"

    RAW_COUNT=$(adb_cmd "ls /data/tombstones/ 2>/dev/null | wc -l")
    TOMB_COUNT=$(echo "$RAW_COUNT" | strip_cr | tr -d ' ')

    log "Tombstone count raw: '$RAW_COUNT' → cleaned: '$TOMB_COUNT'"

    if [[ "$TOMB_COUNT" =~ ^[0-9]+$ ]] && [ "$TOMB_COUNT" -gt 0 ]; then
        log "Found $TOMB_COUNT tombstone(s) — pulling..."
        adb pull /data/tombstones/ "$OUTPUT_DIR/tombstones/" 2>/dev/null || {
            warn "Direct pull failed — using sdcard relay"
            adb_cmd "cp -r /data/tombstones/ $DEVICE_TMP/ 2>/dev/null" || true
            adb pull "$DEVICE_TMP/tombstones" "$OUTPUT_DIR/tombstones/" 2>/dev/null || true
        }
    else
        warn "No tombstones found (count='$TOMB_COUNT') or /data/tombstones/ inaccessible"
    fi

    adb_cmd "cp -r /data/anr/ $DEVICE_TMP/anr 2>/dev/null" || true
    adb pull "$DEVICE_TMP/anr" "$OUTPUT_DIR/anr/" 2>/dev/null || \
        warn "ANR traces not accessible"

    adb_cmd "cp -r /data/system/dropbox/ $DEVICE_TMP/dropbox 2>/dev/null" || true
    adb pull "$DEVICE_TMP/dropbox" "$OUTPUT_DIR/system/dropbox" 2>/dev/null || \
        warn "Dropbox not accessible"
}

collect_memory_logs() {
    title "Memory"
    adb_cmd "cat /proc/meminfo"  > "$OUTPUT_DIR/memory/meminfo.txt"  || true
    adb_cmd "cat /proc/vmstat"   > "$OUTPUT_DIR/memory/vmstat.txt"   || true
    adb_cmd "dumpsys meminfo"    > "$OUTPUT_DIR/memory/dumpsys_meminfo.txt" || true
    adb_cmd "cat /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null" \
        > "$OUTPUT_DIR/memory/dmabuf.txt" || true
}

collect_power_logs() {
    title "Power & Battery"
    adb_cmd "dumpsys battery"  > "$OUTPUT_DIR/power/battery.txt"  || true
    adb_cmd "dumpsys power"    > "$OUTPUT_DIR/power/power.txt"    || true
    adb_cmd "cat /sys/kernel/debug/wakeup_sources 2>/dev/null" \
        > "$OUTPUT_DIR/power/wakeup_sources.txt" || true
    adb_cmd "cat /sys/kernel/debug/suspend_stats 2>/dev/null" \
        > "$OUTPUT_DIR/power/suspend_stats.txt"  || true
}

collect_selinux_logs() {
    title "SELinux"
    grep -iE "avc|selinux|denied" \
        "$OUTPUT_DIR/kernel/dmesg.txt" \
        > "$OUTPUT_DIR/selinux/avc_dmesg.txt" 2>/dev/null || true

    adb logcat -b all -d 2>/dev/null | \
        grep -iE "avc|selinux|denied" \
        > "$OUTPUT_DIR/selinux/avc_logcat.txt" 2>/dev/null || true

    adb_cmd "getenforce" > "$OUTPUT_DIR/selinux/mode.txt" || true
    SEMODE=$(cat "$OUTPUT_DIR/selinux/mode.txt" 2>/dev/null || echo "unknown")
    log "SELinux mode: $SEMODE"
}

collect_system_state() {
    title "System State"
    adb_cmd "dumpsys activity"  > "$OUTPUT_DIR/system/activity.txt"  || true
    adb_cmd "dumpsys window"    > "$OUTPUT_DIR/system/window.txt"    || true
    adb_cmd "dumpsys cpuinfo"   > "$OUTPUT_DIR/system/cpuinfo.txt"   || true
    adb_cmd "service list"      > "$OUTPUT_DIR/system/services.txt"  || true
    adb_cmd "getprop"           > "$OUTPUT_DIR/system/getprop.txt"   || true
    adb_cmd "df -h"             > "$OUTPUT_DIR/system/disk.txt"      || true
    adb_cmd "top -b -n 1"       > "$OUTPUT_DIR/system/top.txt"       || true
    adb_cmd "ps -A"             > "$OUTPUT_DIR/system/ps.txt"        || true
}

collect_hal_logs() {
    title "HAL (Audio / Camera / Display / Sensors)"

    adb_cmd "dumpsys audio"        > "$OUTPUT_DIR/hal/audio.txt"   || true
    adb_cmd "dumpsys media.camera" > "$OUTPUT_DIR/hal/camera.txt"  || true
    adb_cmd "dumpsys sensorservice"> "$OUTPUT_DIR/hal/sensors.txt" || true
    adb_cmd "dumpsys display"      > "$OUTPUT_DIR/hal/display.txt" || true

    log_filtered_dmesg "audio|sound|msm-dai|q6afe|slimbus" "$OUTPUT_DIR/hal/audio_dmesg.txt"
    log_filtered_dmesg "camera|csid|csiphy|vfe|cpp|cci"    "$OUTPUT_DIR/hal/camera_dmesg.txt"
    log_filtered_dmesg "drm|mdss|dsi|panel"                 "$OUTPUT_DIR/hal/display_dmesg.txt"
}

cleanup_device() {
    adb_cmd "rm -rf $DEVICE_TMP" 2>/dev/null || true
}

compress_output() {
    title "Compressing"
    ARCHIVE="veux_logs_${TIMESTAMP}.tar.gz"
    if tar -czf "$ARCHIVE" "$OUTPUT_DIR/" 2>/dev/null; then
        ARCHIVE_SIZE=$(du -sh "$ARCHIVE" 2>/dev/null | awk '{print $1}')
        log "Archive: $ARCHIVE ($ARCHIVE_SIZE)"
    else
        warn "Compression failed — raw folder available: $OUTPUT_DIR"
    fi
}

print_summary() {
    title "Summary"
    echo ""
    find "$OUTPUT_DIR" -type f | sort | while IFS= read -r f; do
        SIZE=$(wc -c < "$f" | tr -d ' ')
        if [ "$SIZE" -gt 100 ] 2>/dev/null; then
            RELPATH="${f#"$OUTPUT_DIR/"}"
            FSIZE=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
            printf "  %-55s %s\n" "$RELPATH" "$FSIZE"
        fi
    done
    echo ""
    TOTAL=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
    log "Total collected: ${TOTAL:-unknown}"
}

main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════╗"
    echo "║  veux Log Collector v1.1 (audited)   ║"
    echo "║  SD695 SM6375 | PixelOS Android 17   ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    setup

    case "$MODE" in
        boot)
            info "Mode: BOOT"
            collect_kernel_logs
            collect_logcat
            collect_selinux_logs
            ;;
        crash)
            info "Mode: CRASH"
            collect_kernel_logs
            collect_logcat
            collect_crash_logs
            collect_selinux_logs
            collect_hal_logs
            ;;
        perf)
            info "Mode: PERF"
            collect_kernel_logs
            collect_thermal_logs
            collect_memory_logs
            collect_power_logs
            collect_qcom_logs
            ;;
        quick)
            info "Mode: QUICK"
            collect_kernel_logs
            collect_logcat
            collect_system_state
            ;;
        full|*)
            info "Mode: FULL"
            collect_kernel_logs
            collect_logcat
            collect_qcom_logs
            collect_thermal_logs
            collect_crash_logs
            collect_memory_logs
            collect_power_logs
            collect_selinux_logs
            collect_system_state
            collect_hal_logs
            ;;
    esac

    cleanup_device
    compress_output
    print_summary

    log "Done → ${OUTPUT_DIR}/"
}

main "$@"
