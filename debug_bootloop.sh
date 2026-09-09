#!/system/bin/sh
#
# debug_bootloop.sh - collect boot debug info from a stuck (Google logo) device
#
# Usage:
#   adb push debug_bootloop.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/debug_bootloop.sh"
#   (or on a non-booting device, from TWRP: sh /data/local/tmp/debug_bootloop.sh)
#
# Output: /data/local/tmp/boot_debug_<timestamp>.tar.gz  ->  adb pull it
#
# Safe mode (skips all modules) is checked via getprop persist.sys.safemode /
# ro.sys.safemode, or force it by holding VOLUME DOWN during boot (kernel-side).
#
# NOTE: dmesg needs root; a non-root shell gets an empty/partial kernel log.

OUTDIR=/data/local/tmp/boot_debug_$$
mkdir -p "$OUTDIR" || exit 1

log() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

# best-effort wrapper: never abort on a failing command
grab() { # grab <outfile> <command...>
    _out="$1"; shift
    ( "$@" ) > "$OUTDIR/$_out" 2>&1
}

log "collecting to $OUTDIR"

# ---------------------------------------------------------------- device info
grab 00_device_info.txt   getprop
grab 01_uname.txt         uname -a
grab 01_uptime.txt        cat /proc/uptime

# ------------------------------------------------------- KernelSU state
log "KernelSU / ksud state"
grab 10_ksud_log.txt      logcat -d -s 'BKI:*' 'KernelSU:*' 'ksud:*' 'SukiSU:*' 'ReSukiSU:*'
grab 11_ksu_syscall.txt   sh -c 'dd if=/dev/kernelsu bs=1 count=8 2>/dev/null | od -c || echo "no /dev/kernelsu (kernel may not be KSU / not booted far enough)"'
grab 12_safemode_props.txt sh -c 'echo "persist.sys.safemode=$(getprop persist.sys.safemode)"; echo "ro.sys.safemode=$(getprop ro.sys.safemode)"; echo "sys.boot_completed=$(getprop sys.boot_completed)"; echo "ro.boottime.init=$(getprop ro.boottime.init)"'
grab 13_ksu_modules_ls.txt sh -c 'ls -la /data/adb/ksu/modules/ 2>/dev/null; echo ---; ls -la /data/adb/modules/ 2>/dev/null || echo "no /data/adb/modules"'

# per-module metadata (name + which scripts it ships) -> "which module does this?"
log "enumerating modules"
{
    for d in /data/adb/ksu/modules/* /data/adb/modules/*; do
        [ -d "$d" ] || continue
        echo "================ $d"
        echo "--- module.prop";    cat "$d/module.prop" 2>/dev/null
        echo "--- skip_update/disable/remove flags:"
        ls -1 "$d" 2>/dev/null | grep -E '^(disable|remove|skip_update|update)$'
        echo "--- scripts present:"
        ls -1 "$d" 2>/dev/null | grep -E '\.(sh|prop)$|^(system|zygisk|webroot)$'
        for s in post-fs-data.sh service.sh late_load.sh post-mount.sh mount.sh uninstall.sh boot-completed.sh; do
            [ -f "$d/$s" ] && { echo "--- $s (head 40)"; head -n 40 "$d/$s"; }
        done
    done
} > "$OUTDIR/14_modules_detail.txt" 2>&1

# module log files written by module scripts
log "module logs"
{
    for d in /data/adb/ksu/modules/* /data/adb/modules/*; do
        [ -d "$d" ] || continue
        for f in "$d/logs/"* "$d"log.txt "$d"logs.txt "$d"/install.log; do
            [ -f "$f" ] && { echo "==== $f"; tail -n 100 "$f"; }
        done
    done
} > "$OUTDIR/15_module_logs.txt" 2>&1

# ------------------------------------------------------- system boot logs
log "system logs"
grab 20_logcat_all.txt    logcat -d -b all -v threadtime
grab 21_logcat_events.txt logcat -d -b events -v time
grab 22_dmesg.txt         dmesg
grab 23_last_kmsg.txt     sh -c 'cat /proc/last_kmsg 2>/dev/null || cat /sys/fs/pstore/console-ramoops* 2>/dev/null || cat /sys/fs/pstore/dmesg-ramoops* 2>/dev/null || echo "no last_kmsg/pstore"'
grab 24_pstore_ls.txt     sh -c 'ls -la /sys/fs/pstore/ 2>/dev/null'
grab 25_init_rc_log.txt   sh -c 'for f in /data/local/tmp/*.log /cache/*.log; do [ -f "$f" ] && { echo "==== $f"; tail -n 200 "$f"; }; done; true'
grab 26_bootanim.txt      sh -c 'ps -A 2>/dev/null | grep -E "bootanim|zygote|surfaceflinger|servicemanager|vold|installd" ; true'
grab 27_westworld.txt     sh -c 'cat /proc/cmdline'

# ------------------------------------------------------- mounts / fs state
log "mounts and overlay state"
grab 30_mounts.txt        cat /proc/mounts
grab 31_overlay_status.txt sh -c 'mount | grep -E "overlay|KSU|ksu|modules" ; true'
grab 32_df.txt            df -h
grab 33_system_prop_err.txt sh -c 'ls -laZ /data/adb/ 2>/dev/null; echo ---; ls -laZ /data/adb/ksu/ 2>/dev/null; echo ---; ls -laZ /data/adb/ksu/modules_update/ 2>/dev/null'

# ------------------------------------------------------- stuck-at-logo helpers
log "watchdog/liveness snapshot (run 3x, 2s apart)"
{
    i=1
    while [ $i -le 3 ]; do
        echo "======== sample $i ($(date))"
        echo "--- zygote alive?";    ps -A 2>/dev/null | grep -c zygote || true
        echo "--- bootanim pid";     ps -A 2>/dev/null | grep bootanim || true
        echo "--- system_server";    ps -A 2>/dev/null | grep system_server || true
        echo "--- last dmesg lines"; dmesg 2>/dev/null | tail -n 20
        i=$((i+1))
        sleep 2
    done
} > "$OUTDIR/40_liveness_samples.txt" 2>&1

# ------------------------------------------------------- package it up
TS=$(date +%Y%m%d_%H%M%S)
TARFILE=/data/local/tmp/boot_debug_${TS}.tar.gz
log "packing $TARFILE"
tar -czf "$TARFILE" -C /data/local/tmp "boot_debug_$$" 2>/dev/null
rm -rf "$OUTDIR"

echo
echo "=========================================================="
echo " DONE. Now on your PC run:"
echo "   adb pull $TARFILE"
echo "=========================================================="
echo " Quick triage hints:"
echo "  * 14_modules_detail.txt : every module + its scripts  -> suspects"
echo "  * 10_ksud_log.txt       : module mounting order/failures"
echo "  * 22/23/24_*            : kernel + previous boot logs"
echo "  * Panic button: hold VOLUME DOWN while booting = KSU safe mode"
echo "    (modules disabled). Or: adb shell su -c 'touch /data/adb/ksu/modules/<id>/disable'"
echo "=========================================================="
