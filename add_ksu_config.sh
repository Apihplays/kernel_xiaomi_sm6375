#!/bin/bash
# ========================================================================
# add_ksu_config.sh – Add CONFIG_KALLSYMS_ALL and CONFIG_DEBUG_KERNEL to veux_defconfig
# ========================================================================
# This script checks if CONFIG_KALLSYMS_ALL is already present in
# arch/arm64/configs/veux_defconfig. If not, it appends the required lines
# for ReSukiSU compatibility.
#
# Usage:
#   ./add_ksu_config.sh        # preview only (dry-run)
#   ./add_ksu_config.sh --apply # actually modify the file
# ========================================================================

set -euo pipefail

DEFCONFIG="arch/arm64/configs/veux_defconfig"
BACKUP="${DEFCONFIG}.bak"

# Check if we are in kernel root
if [ ! -f "$DEFCONFIG" ]; then
    echo "ERROR: $DEFCONFIG not found. Are you in the kernel source root?" >&2
    exit 1
fi

# Check if the needed lines are already present
if grep -q "^CONFIG_KALLSYMS_ALL=y" "$DEFCONFIG"; then
    echo "CONFIG_KALLSYMS_ALL=y already present in $DEFCONFIG"
    exit 0
fi

# Dry-run mode
if [ "${1:-}" != "--apply" ]; then
    echo "DRY-RUN: The following lines will be appended to $DEFCONFIG:"
    echo ""
    echo "# ReSukiSU requirement"
    echo "CONFIG_DEBUG_KERNEL=y"
    echo "CONFIG_KALLSYMS_ALL=y"
    echo ""
    echo "No changes were made. To apply, run: $0 --apply"
    exit 0
fi

# Apply mode: backup and append
echo "Applying changes to $DEFCONFIG"
cp -f "$DEFCONFIG" "$BACKUP"
echo "# ReSukiSU requirement" >> "$DEFCONFIG"
echo "CONFIG_DEBUG_KERNEL=y" >> "$DEFCONFIG"
echo "CONFIG_KALLSYMS_ALL=y" >> "$DEFCONFIG"

echo "Done. Backup saved as $BACKUP"
echo "You can now rebuild your kernel; these options will be set permanently."
