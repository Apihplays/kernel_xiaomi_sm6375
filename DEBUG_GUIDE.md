# Kernel Debugging Guide

## Quick Check (after flashing)

```bash
# Verify kernel version
adb shell uname -r
adb shell cat /proc/version

# Check if XXKSU is running
adb shell "su -c 'ksu --version'"

# Check kernel config (if CONFIG_IKCONFIG=y)
adb shell "zcat /proc/config.gz | grep KSU"
```

## dmesg (kernel log)

```bash
# Full kernel log (needs root)
adb shell "su -c 'dmesg'"

# Filter for specific topics
adb shell "su -c 'dmesg | grep -i ksu'"
adb shell "su -c 'dmesg | grep -i error'"
adb shell "su -c 'dmesg | grep -i wifi'"
adb shell "su -c 'dmesg | grep -i display'"
adb shell "su -c 'dmesg | grep -i audio'"
adb shell "su -c 'dmesg | grep -i thermal'"
adb shell "su -c 'dmesg | grep -i battery'"

# Save full log to file
adb shell "su -c 'dmesg'" > dmesg.log

# Last 100 lines
adb shell "su -c 'dmesg | tail -100'"

# Follow live
adb shell "su -c 'dmesg -w'"
```

## Boot Issues

```bash
# Check if device booted successfully
adb shell getprop sys.boot_completed

# Check boot reason
adb shell getprop ro.boot.bootreason

# Check last reboot reason
adb shell "cat /sys/class/reboot_reason/reboot_reason 2>/dev/null"
adb shell getprop persist.sys.boot.reason

# Check kernel cmdline
adb shell cat /proc/cmdline

# Check uptime (if device keeps rebooting, uptime will be short)
adb shell cat /proc/uptime
```

## Partition Info

```bash
# Check boot partition
adb shell "ls -la /dev/block/by-name/boot*"

# Check current slot
adb shell getprop ro.boot.slot_suffix

# Check dtbo partition
adb shell "ls -la /dev/block/by-name/dtbo*"

# Check vendor_boot
adb shell "ls -la /dev/block/by-name/vendor_boot*"
```

## Hardware Debugging

```bash
# WiFi
adb shell "su -c 'dmesg | grep -i wlan'"
adb shell "su -c 'iwconfig' 2>/dev/null || true"

# Display
adb shell "su -c 'dmesg | grep -i mdss'"
adb shell "su -c 'dumpsys SurfaceFlinger | head -20'"

# Audio
adb shell "su -c 'dmesg | grep -i audio'"
adb shell "su -c 'cat /proc/asound/cards'"

# Thermal
adb shell "su -c 'cat /sys/class/thermal/thermal_zone*/temp'"
adb shell "su -c 'dmesg | grep -i thermal'"

# Battery/Charger
adb shell "su -c 'dumpsys battery'"
adb shell "su -c 'cat /sys/class/power_supply/*/status'"

# NFC
adb shell "su -c 'dmesg | grep -i nfc'"

# IR
adb shell "su -c 'ls /dev/lirc* 2>/dev/null'"

# Fingerprint
adb shell "su -c 'dmesg | grep -i fingerprint'"
```

## Kernel Config Check

```bash
# Full config
adb shell "su -c 'zcat /proc/config.gz'" > kernel_config.txt

# Specific checks
adb shell "su -c 'zcat /proc/config.gz | grep -E \"CONFIG_KSU|CONFIG_LTO|CONFIG_THINLTO|CONFIG_DEBUG\"'"
```

## Performance

```bash
# CPU frequency
adb shell "su -c 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq'"

# Memory
adb shell "cat /proc/meminfo | head -10"

# Uptime and load
adb shell "uptime"

# Process list
adb shell "su -c 'ps -A | head -20'"
```

## Flashing from Recovery

```bash
# Reboot to recovery
adb reboot recovery

# Reboot to bootloader/fastboot
adb reboot bootloader

# Flash boot image directly (if needed)
adb reboot bootloader
fastboot flash boot out/arch/arm64/boot/Image
fastboot reboot
```

## Common Issues

### Bootloop after flash

1. Boot to recovery (hold Vol Up + Power)
2. Flash original kernel zip from /sdcard
3. Or flash stock boot.img via fastboot:
   ```bash
   adb reboot bootloader
   fastboot flash boot boot.img
   fastboot reboot
   ```

### WiFi broken after flash

```bash
# Check if WiFi firmware loaded
adb shell "su -c 'dmesg | grep -i wlan'"
adb shell "su -c 'ls /vendor/firmware/wlan*'"

# Check CNSS driver
adb shell "su -c 'dmesg | grep -i cnss'"
```

### Display issues

```bash
# Check display HAL
adb shell "su -c 'dmesg | grep -i display'"
adb shell "su -c 'dumpsys display | grep -i physical'"

# Check DTB patching (our ak3-custom.sh should handle this)
adb shell "su -c 'dmesg | grep -i mdss'"
```

### No sound

```bash
# Check audio cards
adb shell "su -c 'cat /proc/asound/cards'"

# Check audio HAL
adb shell "su -c 'ls /vendor/lib/hw/audio.primary*'"

# Check DTB audio config (ak3-custom.sh patches this)
adb shell "su -c 'dmesg | grep -i audio'"
```

## Logcat (Android framework)

```bash
# Full logcat
adb logcat -d > logcat.log

# Filter for kernel-related
adb logcat -d | grep -i "kernel\|Ksu\|dmesg"

# System server
adb logcat -d -s SystemServer
```

## KernelSU Specific

```bash
# Check XXKSU version
adb shell "su -c 'ksu --version'"

# Check kernel version
adb shell "su -c 'uname -r'"

# Check if SELinux is permissive (required for some root features)
adb shell "su -c 'getenforce'"

# Check app profiles
adb shell "su -c 'ksu --list'"
```
