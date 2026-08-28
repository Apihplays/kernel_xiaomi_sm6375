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

- **Full/Thin LTO**: `CONFIG_LTO_CLANG=y` always. `CONFIG_THINLTO=y` (current) for lighter
  RAM/CPU during link; `CONFIG_THINLTO=n` = Full Monolithic LTO at `--lto-O3` (Makefile:957,
  heavier but max cross-module opt). CFLAG level is `-O2` (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y`);
  LTO promotes to `-O3` whole-program at link time.
- **PREEMPT**: `CONFIG_PREEMPT=y` (+ `PREEMPT_COUNT`, `PREEMPTION`, `PREEMPT_RCU`).
  Not `PREEMPT_RT`.
- **SMP**: `CONFIG_SMP=y` (arm64 `def_bool y`, cannot disable). All 8 SM6375 cores online.
- **HZ**: `CONFIG_HZ_100=y` (inherited from positron/nebula base; intentional, NOT bumped).
- **KERNEL NAME**: Set via the repo-root `localversion` file (currently `-ksun`). IMPORTANT: this
  QGKI/positron fork IGNORES `CONFIG_LOCALVERSION` in the defconfig — the `localversion` file
  is the only mechanism that sets the suffix (that's why the base showed `~positron`).
  A git commit hash is always appended by `scripts/setlocalversion` (the fork stripped the
  `CONFIG_LOCALVERSION_AUTO` gate), giving e.g. `5.4.302-ksun/45b87311`. That hash is cosmetic
  and identifies the build commit — leave it. Do NOT put `~positron` back in `localversion`.
- **DEBUG_INFO disabled**: `CONFIG_DEBUG_INFO=n` because LLVM 22 (Clang/LLD 22.1.2) emits
  DWARF-5 relocations incompatible with `ld.lld` + ThinLTO/Full LTO
  (`unknown relocation (256)`). This is a toolchain bug, not our code.
  (`androidboot.debuggable=1` in cmdline is separate and still enables `adb root`.)
- **clang/libxml2 noise**: `ld.lld: ... libxml2.so.2: no version information available`
  is harmless (Clang 22 private lib path); ignore it.

## Defconfig Alignment Methodology

- Base = `arch/arm64/configs/vendor/nebula_veux_defconfig.txt` (nebula defconfig text).
- IMPORTANT: the nebula *defconfig text file* has no `CONFIG_KSU`, BUT the actual
  `nebula-veux-*.zip` Image DOES contain KernelSU (verified: `drivers/kernelsu/allowlist.c`
  strings, `kernelsu_work_queue`, etc.). So the defconfig text is NOT representative of the
  shipped nebula build — nebula ships a leaner KSU than ours. Do NOT assume "nebula has no KSU".
- Diff our `veux_defconfig` vs nebula and justify every diff. Intentional diffs:
  `LOCALVERSION="-ksun"`, `CONFIG_KSU*` hooks, `CONFIG_DEBUG_INFO=n`.
- `androidboot.debuggable=1` was REMOVED from our `CONFIG_CMDLINE` (it was the only non-KSU
  cmdline divergence vs nebula and a suspected `system_server` EMFILE/-24 soft-reboot cause).
- Do NOT copy nebula's defconfig verbatim — it drops `CONFIG_KSU` and would silently lose root
  after `make olddefconfig` unless we re-add it.

## system_server Crash / Soft-Reboot — Cause Checklist

Symptom: `system_server` FATAL → `audio.service` SIGSEGV → framework restart (looks like
soft-reboot). Latest evidence (`veux_logs_20260828_131940`): crash at `logcat_all.txt:3626`
`synchronizeKernelRCU failed: -24` from `BpfNetMaps.swapActiveStatsMap()`; kernel dmesg shows
NO panic/RCU stall/watchdog/OOM. `-24` = EMFILE (fd exhaustion). Conclusion: **userspace fd
exhaustion, kernel stable. Nebula (also has KSU) is stable → differentiator is our cmdline/fd
scope, not KSU presence.**

Checklist (ranked; tick with `./veux_master_collector.sh ksu` or `crash` after reflash):

- [x] **#1 `androidboot.debuggable=1`** — REMOVED from cmdline (matched nebula). Was the only
      non-KSU cmdline diff; debuggable inflates `system_server` fd surface → EMFILE on A17
      `swapActiveStatsMap`. (PRIMARY suspect, now fixed — validate by flashing.)
- [ ] **#2 Full KSU-Next fd-apparatus** (`ksu_fdwrapper`/`ksu_install_fd`/`ksu_obs` pkg_observer)
      — ours has these, nebula's KSU is leaner. If #1 fix insufficient, disable `ksu_obs`/fd layer.
- [ ] **#3 Stale metamodule** `hybrid_mount/update` flag + `/data/adb/metamodule` symlink.
- [ ] **#4 `rcupdate.rcu_expedited=1`** (nebula-aligned; test-flip only if #1 persists).
- [ ] **#5 BPF map limit** (real kernel tuning candidate). Check `ksu/maxfiles.txt`, `bpf_map_count.txt`.
- [ ] **#6 `audio.service` SIGSEGV** cascade — `ksu/tombstone_audio.txt`.
- [ ] **#7 memcg LRU underflow** — clamped in `mm/memcontrol.c`; verify absent in new log.
- [ ] **#8 Vendor HAL timeout** / **#9 `debuggable` tracing stress** / **#10 KSU supercall kernel bug**.
- Ruled OUT by 131940: kernel panic, SELinux AVC on ksu, OOM, binder storm, LRU underflow.

## Git / Workflow

- Branch `ksun` is the working branch; `main` is the fork base (only `main` on GitHub remote
  per user request — delete stray branches).
- KernelSU-Next is a submodule (`KernelSU-Next/`). Patch it with `git commit` INSIDE the
  submodule first, then `git add KernelSU-Next` + commit in the parent.
- Commit style (from upstream KSU): `<scope>: <summary>`, lowercase scope
  (`kernel`, `defconfig`, `ksu`, `build`, `tools`), concise, no trailing period.
- Clean history: no secrets, no `*.img`/`*.zip`/`*.log` in commits (use `git filter-repo`
  if needed).
