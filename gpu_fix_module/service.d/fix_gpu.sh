#!/system/bin/sh
# Force GPU to max frequency - workaround for TZ clock lock
sleep 5
echo performance > /sys/class/kgsl/kgsl-3d0/devfreq/governor
echo 1 > /sys/class/kgsl/kgsl-3d0/force_clk_on
echo 1 > /sys/class/kgsl/kgsl-3d0/force_bus_on
echo 1 > /sys/class/kgsl/kgsl-3d0/force_rail_on
echo 1 > /sys/class/kgsl/kgsl-3d0/force_no_nap
echo 0 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel
echo 840000000 > /sys/class/kgsl/kgsl-3d0/max_gpuclk
