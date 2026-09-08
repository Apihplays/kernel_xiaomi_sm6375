#!/bin/bash
# ========================================================================
# apply_ksu_hooks.sh - Apply missing ReSukiSU manual hooks to kernel source
# ========================================================================
# Usage: Run from your kernel root directory.
#   ./apply_ksu_hooks.sh
#
# It will detect which hooks are missing and apply them based on your
# kernel version (5.4). The script is idempotent – running it multiple
# times will not duplicate hooks.
#
# It backs up each modified file with a .bak extension before applying.
# ========================================================================

set -euo pipefail

# Ensure we are in kernel root
if [ ! -f "Makefile" ]; then
    echo "ERROR: No Makefile found. Are you in the kernel source root?" >&2
    exit 1
fi

# Detect kernel version
KERNEL_VERSION=$(grep -E "^VERSION =" Makefile | awk '{print $3}')
PATCHLEVEL=$(grep -E "^PATCHLEVEL =" Makefile | awk '{print $3}')
SUBLEVEL=$(grep -E "^SUBLEVEL =" Makefile | awk '{print $3}')
echo "Detected kernel: $KERNEL_VERSION.$PATCHLEVEL.$SUBLEVEL"

# ----------------------------------------------------------------------
# Helper: check if a symbol already exists in a file
# ----------------------------------------------------------------------
symbol_exists() {
    grep -q "$1" "$2" 2>/dev/null
}

# ----------------------------------------------------------------------
# Patch functions (each modifies the target file if hook is missing)
# ----------------------------------------------------------------------

# 1. execveat hook (ksu_handle_execveat)
apply_execveat_hook() {
    local file="fs/exec.c"
    local symbol="ksu_handle_execveat"
    if symbol_exists "$symbol" "$file"; then
        echo "[OK] $symbol already present in $file"
        return 0
    fi
    echo "[APPLY] Adding $symbol to $file"
    cp -f "$file" "$file.bak"

    # Add the extern declaration before do_execveat_common
    # We'll insert after the existing includes and before the function definition.
    # We'll search for "static int do_execveat_common" and insert before it.
    # But we also need to add the call inside do_execveat_common.
    # We'll use sed to insert the declaration and call.

    # Insert declaration before do_execveat_common
    sed -i '/^static int do_execveat_common/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
__attribute__((hot))\
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\
				void *argv, void *envp, int *flags);\
#endif' "$file"

    # Insert call inside do_execveat_common after the function opening brace
    # We'll find the line with "static int do_execveat_common" and the next line with "{".
    # We'll insert after that opening brace.
    sed -i '/^static int do_execveat_common/,/^{/ {
        /^{/a\
#ifdef CONFIG_KSU_MANUAL_HOOK\
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\
#endif
    }' "$file"

    echo "[DONE] $symbol added"
}

# 2. stat hooks: newfstat and fstat64 (ksu_handle_newfstat_ret, ksu_handle_fstat64_ret)
apply_stat_hooks() {
    local file="fs/stat.c"
    local sym1="ksu_handle_newfstat_ret"
    local sym2="ksu_handle_fstat64_ret"
    local needs_patch=0
    if ! symbol_exists "$sym1" "$file"; then
        needs_patch=1
    fi
    if ! symbol_exists "$sym2" "$file"; then
        needs_patch=1
    fi
    if [ $needs_patch -eq 0 ]; then
        echo "[OK] stat hooks already present in $file"
        return 0
    fi
    echo "[APPLY] Adding stat hooks to $file"
    cp -f "$file" "$file.bak"

    # Add declarations after the existing includes and before SYSCALL_DEFINE2(newfstat)
    # Insert before SYSCALL_DEFINE2(newfstat)
    sed -i '/^SYSCALL_DEFINE2(newfstat,/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
__attribute__((hot))\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\
				int *flags);\
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);\
#ifdef __ARCH_WANT_STAT64 || defined(__ARCH_WANT_COMPAT_STAT64)\
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);\
#endif\
#endif' "$file"

    # Insert call in SYSCALL_DEFINE2(newfstat) after the error check and before return
    # We'll find the line with "return error;" and insert before it.
    sed -i '/^SYSCALL_DEFINE2(newfstat,/,/^}/ {
        /return error;/i\
#ifdef CONFIG_KSU_MANUAL_HOOK\
	ksu_handle_newfstat_ret(&fd, &statbuf);\
#endif
    }' "$file"

    # Insert call in SYSCALL_DEFINE2(fstat64) similarly
    sed -i '/^SYSCALL_DEFINE2(fstat64,/,/^}/ {
        /return error;/i\
#ifdef CONFIG_KSU_MANUAL_HOOK\
	ksu_handle_fstat64_ret(&fd, &statbuf);\
#endif
    }' "$file"

    echo "[DONE] stat hooks added"
}

# 3. sys_reboot hook (ksu_handle_sys_reboot)
apply_reboot_hook() {
    local file="kernel/reboot.c"
    local symbol="ksu_handle_sys_reboot"
    if symbol_exists "$symbol" "$file"; then
        echo "[OK] $symbol already present in $file"
        return 0
    fi
    echo "[APPLY] Adding $symbol to $file"
    cp -f "$file" "$file.bak"

    # Add declaration before SYSCALL_DEFINE4(reboot, ...)
    sed -i '/^SYSCALL_DEFINE4(reboot,/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\
#endif' "$file"

    # Insert call inside SYSCALL_DEFINE4(reboot, ...) after the variable declarations
    # We'll insert after the line "int ret = 0;" or after the declarations.
    sed -i '/^SYSCALL_DEFINE4(reboot,/,/^}/ {
        /int ret = 0;/a\
#ifdef CONFIG_KSU_MANUAL_HOOK\
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\
#endif
    }' "$file"

    echo "[DONE] $symbol added"
}

# ----------------------------------------------------------------------
# Main execution
# ----------------------------------------------------------------------
echo "===== Applying missing ReSukiSU hooks ====="

apply_execveat_hook
apply_stat_hooks
apply_reboot_hook

# Note: faccessat and stat hooks are already present (as per build log)
# We do not need to apply static exports because CONFIG_KALLSYMS_ALL is enabled
# in your build script, which satisfies ReSukiSU's requirement.

echo "===== All missing hooks applied ====="
echo "You can now rebuild your kernel."
echo "Modified files have .bak backups in case of issues."
