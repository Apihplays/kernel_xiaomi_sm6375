# Kernel Build Agent Guide — ksun (veux / SM6375)

Forked from positron (QGKI 5.4.302) base, integrating KernelSU-Next. Target: Redmi
Note 11 Pro 5G (veux), SM6375 holi, PixelOS Android 17.

## Quick Start

- Significant refactors: sketch a plan first (`.hermes/plans/`), keep it updated.
- Use `rg`/search_files for searching; keep edits ASCII unless file already uses non-ASCII.
- Build with `./build_kernel.sh clean` (runs `make mrproper` + ThinLTO, 12 threads via `nproc --all`).
- **One-command build+release:** `./build_and_release.sh` — removes old zips, clean build,
  packages, then creates a GitHub Release (prerelease, `--target ksun`) with the zip as asset.
  Requires `gh` authenticated (currently: Apihplays, SSH protocol, `repo` scope) OR a
  `GITHUB_TOKEN`/`GH_PAT` env var. If neither, it builds+packages and SKIPs upload.
- Never commit `*.zip`, `*.img`, `*.log`, `diag-*/`, or `.hermes/` planning files to GitHub
  (user rule). `.gitignore` already excludes them.
- SSH push only. HTTPS auth fails for this repo.

## Remote Access (9Remote)

For building from elsewhere, `9remote` (v2.5.8) runs a cloudflared tunnel — no port 22,
no router forward, no brute-force surface. Start it headless:
```bash
9remote start        # brings up Web UI on :2208 + trycloudflare tunnel (~40s to bind)
```
Connect from anywhere: https://9remote.cc/login  (use the permanent key or a one-time key
from `9remote otk`). The interactive TUI (`9remote` with a TTY) "Open Web UI (background)"
is equivalent; `9remote start` is the headless path. Keep the process alive (background).

## KernelSU Integration (KernelSU-Next v3.1.0-legacy)

Source of truth for KSU concepts: midori01/KernelSU `AGENTS.md`
(https://raw.githubusercontent.com/midori01/KernelSU/refs/heads/main/AGENTS.md).

### Manual hook mode (this kernel)
Kernel 5.4 kprobe is unreliable on SM6375, so we use **manual hooks**, not kprobe
auto-hook. Required defconfig:
```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_LEAN=y          # strips fd-apparatus (see below)
# CONFIG_MODULES is NOT set (manual mode does not need it; enabling it + Full LTO
#   triggers ALIGN_CFI linker error on .ko builds)
```
Manual hook call sites patched into kernel source (do NOT remove these):
- `fs/exec.c`      — `ksu_handle_execveat`
- `fs/open.c`      — `ksu_handle_faccessat`
- `fs/read_write.c`— `ksu_handle_sys_read` (gated by `ksu_vfs_read_hook`)
- `fs/stat.c`      — `ksu_handle_stat`
- `kernel/reboot.c`— `ksu_handle_sys_reboot`

(Note: resukisu/ReSukiSU also requires manual hooks — 5 sites across 4 files
exec/open/stat/reboot + optional read_write — and its `manual_hook_check.mk` FAILS the
build if any hook is missing. We studied it and RULED IT OUT as a KSU swap: resukisu has
NO `CONFIG_KSU_LEAN` and REQUIRES `ksu_handle_faccessat` (fd-based su) — that is the exact
fd-apparatus we stripped. Switching would re-add the soft-reboot cause.)

### CONFIG_KSU_LEAN — the soft-reboot fix
Our KSU-Next (v3.1.0-legacy) compiles a full fd-injection apparatus by default:
`file_wrapper.o` (ksu_fdwrapper/ksu_install_fd), `pkg_observer.o` (ksu_obs), and
`throne_tracker.c` (track_throne). On A17, `system_server` opens many fds during BPF
netstats rotation; our KSU pushes it over the limit → `EMFILE (-24)` →
`synchronizeKernelRCU failed` → soft-reboot (framework restart).
`CONFIG_KSU_LEAN=y` (our addition to `kernel/Kconfig`) excludes `file_wrapper.o` +
`pkg_observer.o` from the build and disables `track_throne()`'s body; `ksu_manager_appid`
(core root state) is kept so root still works. Verified: built Image has
`ksu_fdwrapper=0, ksu_install_fd=0, track_throne=0, Tksu_obs=0`. This matches nebula's
observed lean KSU scope (nebula's Image has NO fd-apparatus symbols).

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
- **Symptom rule (CORRECTED):** `synchronizeKernelRCU failed: -24` was originally blamed
  on a broken/spoofed Manager (userspace). Deeper analysis + the nebula comparison proved
  the KERNEL-SIDE fd-apparatus (KSU-Next full build) IS a real cause on A17 — `CONFIG_KSU_LEAN`
  removes it. So: if the lean build still soft-reboots, THEN it's userspace (stale metamodule,
  spoofed Manager). Fix kernel side first (done), then device side if needed.

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

- **LTO**: `CONFIG_LTO_CLANG=y` always. **ThinLTO** (`CONFIG_THINLTO=y`) — switched from Full
  LTO because the user's PC lagged. Full LTO = `CONFIG_THINLTO=n` at `--lto-O3` (Makefile:957).
  CFLAG level is `-O2` (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y`); LTO promotes to `-O3` at link.
- **PREEMPT**: `CONFIG_PREEMPT=y` (+ `PREEMPT_COUNT`, `PREEMPTION`, `PREEMPT_RCU`). Not `PREEMPT_RT`.
- **SMP**: `CONFIG_SMP=y` (arm64 `def_bool y`, cannot disable). All 8 SM6375 cores online.
- **HZ**: `CONFIG_HZ_100=y` (inherited from positron/nebula base; intentional, NOT bumped).
- **KERNEL NAME**: Set via the repo-root `localversion` file (currently `-ksun`). IMPORTANT: this
  QGKI/positron fork IGNORES `CONFIG_LOCALVERSION` in the defconfig — the `localversion` file
  is the only mechanism that sets the suffix. A git commit hash is always appended by
  `scripts/setlocalversion` (fork stripped the `CONFIG_LOCALVERSION_AUTO` gate), e.g.
  `5.4.302-ksun/78cc3601`. That hash is cosmetic — leave it.
- **DEBUG_INFO disabled**: `CONFIG_DEBUG_INFO=n` because LLVM 22 (Clang/LLD 22.1.2) emits
  DWARF-5 relocations incompatible with `ld.lld` + ThinLTO/Full LTO (`unknown relocation (256)`).
  Toolchain bug, not our code. (`androidboot.debuggable=1` in cmdline is separate.)
- **clang/libxml2 noise**: `ld.lld: ... libxml2.so.2: no version information available`
  is harmless (Clang 22 private lib path); ignore it.

## Defconfig Alignment Methodology

- Base = `arch/arm64/configs/vendor/nebula_veux_defconfig.txt` (nebula defconfig text).
- IMPORTANT: the nebula *defconfig text file* has no `CONFIG_KSU`, BUT the actual
  `nebula-veux-*.zip` Image DOES contain KernelSU (verified: `drivers/kernelsu/allowlist.c`
  strings, `kernelsu_work_queue`). So the defconfig text is NOT representative of the shipped
  nebula build — nebula ships a **lean** KSU (no fd-apparatus), which is exactly what
  `CONFIG_KSU_LEAN` replicates. Do NOT assume "nebula has no KSU".
- The PUBLIC nebula *source* repo (`frost-testzone/kernel_xiaomi_sm6375`) has **NO KSU at all**
  (LineageOS `android_kernel_qcom_sm8350` base, `CONFIG_QGKI=y`, 5.4.302). The KSU in the
  nebula ZIP comes from a separate/private integration we cannot see. So we build our own KSU.
- `androidboot.debuggable=1` was REMOVED from our `CONFIG_CMDLINE` (it was the only non-KSU
  cmdline divergence vs nebula). Harmless change (proven: shipped cmdline never had it via
  `CONFIG_CMDLINE_EXTEND`); not the root cause, but matched nebula.
- Do NOT copy nebula's defconfig verbatim — it drops `CONFIG_KSU` and would silently lose root.

## system_server Crash / Soft-Reboot — Cause Checklist

Symptom: `system_server` FATAL → `audio.service` SIGSEGV → framework restart (soft-reboot look).
Evidence (`veux_logs_20260828_131940`): crash at `logcat_all.txt:3626`
`synchronizeKernelRCU failed: -24` from `BpfNetMaps.swapActiveStatsMap()`; kernel dmesg clean.
`-24` = EMFILE (fd exhaustion).

Checklist (ranked; tick with `./veux_master_collector.sh ksu` or `crash` after reflash):

- [x] **#1 `androidboot.debuggable=1`** — REMOVED from cmdline (matched nebula).
- [x] **#2 KSU fd-apparatus** — FIXED via `CONFIG_KSU_LEAN=y`. Verified all 4 fd symbols = 0
      in built Image (`ksun-veux-20260828-212139.zip`, `5.4.302-ksun/78cc3601`). This matches
      nebula's lean KSU scope.

## Validation (evidence chain)

**Root cause PROVEN on-device:** User flashed **nebula** (which ships a lean KSU with NO
fd-apparatus) and confirmed **NO soft-reboot**. This empirically isolates the KSU fd-apparatus
as the differentiator — our full-KSU build crashed `system_server` with EMFILE/-24 on A17,
nebula's lean KSU did not. The earlier "userspace Manager only" theory is superseded.

**Open validation:** The latest lean-ksun build (`ksun-veux-20260828-212139.zip`,
`5.4.302-ksun/78cc3601`) has NOT yet been flashed. The hypothesis to confirm: with
`CONFIG_KSU_LEAN` stripping the same fd-apparatus nebula lacks, our ksun build should now
behave like nebula (no soft-reboot). Flash it, daily-drive, and trigger the same workload
that crashed before (unlock + heavy net use). If stable → root cause closed. If it still
reboots → fall through to #3–#10 below (metamodule / RCU / BPF / audio SIGSEGV / etc.),
collect via `./veux_master_collector.sh ksu` (Termux `su`, since `debuggable=1` is gone so
`adb root` won't work).

- [ ] **#3 Stale metamodule** `hybrid_mount/update` flag + `/data/adb/metamodule` symlink.
- [ ] **#4 `rcupdate.rcu_expedited=1`** (nebula-aligned; test-flip only if #2 persists).
- [ ] **#5 BPF map limit** (real kernel tuning candidate). Check `ksu/maxfiles.txt`, `bpf_map_count.txt`.
- [ ] **#6 `audio.service` SIGSEGV** cascade — `ksu/tombstone_audio.txt`.
- [ ] **#7 memcg LRU underflow** — clamped in `mm/memcontrol.c`; verify absent in new log.
- [ ] **#8 Vendor HAL timeout** / **#9 `debuggable` tracing stress** / **#10 KSU supercall kernel bug**.
- Ruled OUT by 131940: kernel panic, SELinux AVC on ksu, OOM, binder storm, LRU underflow.

## CI / Automated Build (forked NonGKI framework)

`Apihplays/NonGKI_Kernel_Build_2nd` is forked from `JackA1ltman/NonGKI_Kernel_Build_2nd`
(a GitHub Actions Non-GKI build framework). It has a per-device workflow
`build-redmi-note11pro-5g-aosp-a16.yml` targeting veux, BUT as-forked it builds the WRONG
kernel (dereference23 base + resukisu KSU + SuSFS). To use it for OUR kernel it MUST be
reconfigured: point `KERNEL_SOURCE` → `Apihplays/kernel_xiaomi_sm6375` branch `ksun`,
`KERNELSU_AUTO_GET: false` (keep our submodule), `SUSFS_ENABLE: false`. Also: our
`KernelSU-Next/` and `AnyKernel3/` are **nested git repos, NOT proper submodules** (no
`.gitmodules`), so a CI `git clone --recursive` gets empty dirs — they must be pushed as real
submodules before CI works. NOT yet wired up; `build_and_release.sh` is the current automation.

## Git / Workflow

- Branch `ksun` is the working branch (pushed to `origin`). `main` is the fork base.
- KernelSU-Next and AnyKernel3 are **nested git repos**, not registered submodules (no
  `.gitmodules`). They are committed as plain directories in our repo (the submodule gitlink
  is NOT tracked). Pushing them to CI requires converting to real submodules first.
- Patch KSU: `git commit` inside `KernelSU-Next/`, then `git add KernelSU-Next` + commit parent.
- Commit style (from upstream KSU): `<scope>: <summary>`, lowercase scope
  (`kernel`, `defconfig`, `ksu`, `build`, `tools`), concise, no trailing period.
- Clean history: no secrets, no `*.img`/`*.zip`/`*.log` in commits (`.gitignore` excludes them).
