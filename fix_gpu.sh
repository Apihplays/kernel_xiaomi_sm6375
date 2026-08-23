#!/bin/bash
# Force GPU to max frequency on veux
# Temporary workaround for TrustZone GPU clock lock issue
set -euo pipefail

echo "Forcing GPU to max frequency..."
adb shell "su -c '
    echo performance > /sys/class/kgsl/kgsl-3d0/devfreq/governor
    echo 1 > /sys/class/kgsl/kgsl-3d0/force_clk_on
    echo 1 > /sys/class/kgsl/kgsl-3d0/force_bus_on
    echo 1 > /sys/class/kgsl/kgsl-3d0/force_rail_on
    echo 1 > /sys/class/kgsl/kgsl-3d0/force_no_nap
    echo 0 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel
    echo 840000000 > /sys/class/kgsl/kgsl-3d0/max_gpuclk
'"

echo "GPU state:"
adb shell "su -c 'cat /sys/class/kgsl/kgsl-3d0/clock_mhz'"
echo "MHz"
adb shell "su -c 'cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage'"
echo "% busy"
