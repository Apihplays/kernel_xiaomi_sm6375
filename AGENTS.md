# Kernel Build Agent Guide — ksun (veux / SM6375)

Forked from positron (QGKI 5.4.302) base, integrating KernelSU-Next. Target: Redmi
Note 11 Pro 5G (veux), SM6375 holi, PixelOS Android 17.

## Quick Start

- Significant refactors: sketch a plan first (`.hermes/plans/`), keep it updated.
- Use `rg`/search_files for searching; keep edits ASCII unless file already uses non-ASCII.
- Build with `./build_kernel.sh clean` (runs `make mrproper` + Full LTO, 12 threads via `nproc --all`).
- Never commit `*.zip`, `*.img`, `*.log`, `diag-*/`, or `.hermes/` planning files to GitHub
  (user rule). `.gitignore` already excludes them.
- SSH push only. HTTPS auth fails for this repo.

## KernelSU Integration (KernelSU-Next v3.1.0-legacy)

Source of truth for KSU concepts: midori01/KernelSU `AGENTS.md`
(https://raw.githubusercontent.com/midori01/KernelSU/refs/heads/main/AGENTS.md).

### Manual hook mode (this kernel)
Kernel 5.4 kprobe is unreliable on SM6375, so we use **manual hooks**, not kprobe
auto-hook. Required defconfig:
```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_MODULES is NOT set (manual mode does not need it; enabling it + Full LTO
#   triggers ALIGN_CFI linker error on .ko builds)
```
Manual hook call sites patched into kernel source (do NOT remove these):
- `fs/exec.c`      — `ksu_handle_execveat`
- `fs/open.c`      — `ksu_handle_faccessat`
- `fs/read_write.c`— `ksu_handle_sys_read` (gated by `ksu_vfs_read_hook`)
- `fs/stat.c`      — `ksu_handle_stat`
- `kernel/reboot.c`— `ksu_handle_sys_reboot`

### Kbuild backport detection (KernelSU-Next/kernel/Kbuild)
The Kbuild injects `can_umount` / `path_umount` into `fs/namespace.c` only if they are
absent. On 5.4 both already exist, so the greps must match loosely
(`grep -qE "can_umount"` not `^static int can_umount`) or it double-defines and fails.
The Kbuild hook-check guard was patched so `KSU_MANUAL_HOOK=n` (kprobe mode) does not
error out; we run manual mode so the guard is satisfied.

### Supercall / userspace contract
- Kernel exposes `[ksu_driver]` anon-inode supercall IOCTLs (`kernel/supercalls.c`).
- Root works when `adb root` succeeds and Manager shows granted UID in allowlist
  (`/data/adb/ksu/.allowlist`).
- **Symptom rule:** `synchronizeKernelRCU failed: -24` or metamodule "custom installer
  is active" errors are USERSPACE Manager issues (broken/spoofed ksud binary, stale
  `/data/adb/metamodule` symlink, pending `update` flag), NOT kernel bugs. Fix on the
  device side, not in kernel source.

## Metamodule State (module flash failures)

ksud enforces ONE active metamodule, symlinks `/data/adb/metamodule -> /data/adb/modules/<id>`,
and blocks all installs while a `update`/`install`/`remove` flag or stale symlink exists
(`check_install_safety()`). To fully clear from a clean slate:
```bash
su -c "rm -rf /data/adb/modules/*"
su -c "rm -rf /data/adb/metamodule"
su -c "rm -f /data/adb/ksu/.modules* /data/adb/ksu/.pending /data/adb/ksu/.installed /data/adb/ksu/modules.list"
su -c reboot
```
See `ksun-full-clean.sh` (repo root). Use the OFFICIAL Manager, never a spoofed package.

## Build Facts (verified)

- **Full LTO = `-O3`**: `Makefile` sets `LD_FLAGS_LTO_CLANG := --lto-O3` with
  `CONFIG_LTO_CLANG=y` + `CONFIG_THINLTO=n`. CFLAG level is `-O2`
  (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y`); LTO promotes to `-O3` whole-program at link.
- **PREEMPT**: `CONFIG_PREEMPT=y` (+ `PREEMPT_COUNT`, `PREEMPTION`, `PREEMPT_RCU`).
  Not `PREEMPT_RT`.
- **SMP**: `CONFIG_SMP=y` (arm64 `def_bool y`, cannot disable). All 8 SM6375 cores online.
- **HZ**: `CONFIG_HZ_100=y` (inherited from positron/nebula base; intentional, NOT bumped).
- **KERNEL NAME**: `CONFIG_LOCALVERSION="-ksun"` in defconfig. IMPORTANT — the repo-root
  `localversion` file OVERRIDES the defconfig suffix with a tilde prefix (e.g. `~positron`).
  Keep `localversion` empty so the kernel reports `5.4.302-ksun`, not `5.4.302~positron`.
- **DEBUG_INFO disabled**: `CONFIG_DEBUG_INFO=n` because LLVM 22 (Clang/LLD 22.1.2) emits
  DWARF-5 relocations incompatible with `ld.lld` + ThinLTO/Full LTO
  (`unknown relocation (256)`). This is a toolchain bug, not our code.
  (`androidboot.debuggable=1` in cmdline is separate and still enables `adb root`.)
- **clang/libxml2 noise**: `ld.lld: ... libxml2.so.2: no version information available`
  is harmless (Clang 22 private lib path); ignore it.

## Defconfig Alignment Methodology

- Base = `arch/arm64/configs/vendor/nebula_veux_defconfig.txt` (nebula, known-good on veux).
- Diff our `veux_defconfig` vs nebula and justify every diff. Allowed intentional diffs:
  `LOCALVERSION="-ksun"`, `CONFIG_KSU*` hooks, `CONFIG_CMDLINE` adds `androidboot.debuggable=1`,
  `CONFIG_DEBUG_INFO=n`.
- Do NOT copy nebula's defconfig verbatim — it drops `CONFIG_KSU` (nebula has no KSU) and
  would silently lose root after `make olddefconfig` unless we re-add it.

## Git / Workflow

- Branch `ksun` is the working branch; `main` is the fork base (only `main` on GitHub remote
  per user request — delete stray branches).
- KernelSU-Next is a submodule (`KernelSU-Next/`). Patch it with `git commit` INSIDE the
  submodule first, then `git add KernelSU-Next` + commit in the parent.
- Commit style (from upstream KSU): `<scope>: <summary>`, lowercase scope
  (`kernel`, `defconfig`, `ksu`, `build`, `tools`), concise, no trailing period.
- Clean history: no secrets, no `*.img`/`*.zip`/`*.log` in commits (use `git filter-repo`
  if needed).
