# veux Kernel Build & AK3 Packaging Plan
> Saved: 2026-09-07 | Device: Redmi Note 11 Pro 5G (SM6375 / holi) | Kernel: 5.4.302 ACK

---

## Context

- **Build script:** `buildveuxv2.sh` (audited, corrections applied)
- **Hook script:** `applyreuki.sh` (ReSukiSU/KernelSU manual hook injector)
- **AnyKernel3:** cloned at `./AnyKernel3/` (stock template, needs veux config)
- **Toolchain:** `~/toolchains/clang-r596125/bin` (Android r596125, Clang 22.0.2, +PGO +BOLT +LTO +MLGO, statically linked, no ICU dependency)
- **CI reference:** `.github/workflows/build-veux.yml` (LLVM 23.1.0, ccache, ICU 70 staging)

---

## Audit Findings (buildveuxv2.sh)

### Verified Working
- Toolchain autodetection: finds `~/toolchains/clang-r596125/bin` (clang + ld.lld + llvm-ar all present)
- KSU symbol checking: 6 symbols (`ksu_handle_execveat`, `ksu_handle_faccessat`, `ksu_handle_stat`, `ksu_handle_newfstat_ret`, `ksu_handle_fstat64_ret`, `ksu_handle_sys_reboot`)
- KALLSYMS_ALL auto-fix: appends `CONFIG_DEBUG_KERNEL=y` + `CONFIG_KALLSYMS_ALL=y` when `CONFIG_KSU=y` and missing
- ThinLTO enable: flips `# CONFIG_THINLTO is not set` → `CONFIG_THINLTO=y`
- BOLT auto-enable: detects `llvm-bolt`, sets `BOLT_ENABLE=1`
- MLGO auto-detect: checks `~/mlgo-model.mlgo` if `MLGO_MODEL` unset
- PGO flags: `PROFILE_GEN=1` / `PROFILE_USE=<path>` properly handled
- KBUILD_CFLAGS/LDFLAGS: `-fno-builtin-wcslen -fno-strict-overflow -fno-merge-all-constants -ffunction-sections -fdata-sections -gc-sections`
- make invocation: `KCFLAGS="$KCFLAGS $KBUILD_CFLAGS"` + KCPPFLAGS + LDFLAGS all passed
- Artifact copying: Image, Image.gz, dtbs to kernel root
- AK3 zip packaging: conditional on `AnyKernel3/` dir existing

### Corrections Made
1. **BOLT objcopy guard** (line ~264): Added `command -v aarch64-linux-gnu-objcopy` check before regenerating Image after BOLT
2. **Suppress redundant config output**: Stripped `# configuration written to .config` noise from `make veux_defconfig` and `make olddefconfig` via `grep -v`
3. **AK3 zip path fix** (line ~296): Replaced unreliable `$OLDPWD` with deterministic `/tmp/$ZIP` then copy to `$OUT_DIR` or `$ROOT`

### Current .config State
All KSU/LTO fixes already applied:
```
CONFIG_KSU=y
CONFIG_KALLSYMS_ALL=y
CONFIG_DEBUG_KERNEL=y
CONFIG_LTO_CLANG=y
CONFIG_THINLTO=y
```
The `!!` warnings in the script **will not fire** on this config (they only trigger when the script actually modifies .config).

---

## AnyKernel3 Status

### Present ✅
- `AnyKernel3/anykernel.sh` — customized for veux/peux (boot + vendor_boot + dtbo sections)
- `AnyKernel3/META-INF/com/google/android/update-binary` (shell-based AK3 backend)
- `AnyKernel3/META-INF/com/google/android/updater-script` (dummy, correct for shell AK3)
- `AnyKernel3/banner` — logo + "ResuKiSU veux kernel" (copied from nebula-veux, edited)
- `AnyKernel3/cmdline` — veux bootargs (copied from nebula-veux)
- `AnyKernel3/dtb` — single veux DTB blob (389400 bytes, Blair QRD), kept as file not dir
- `AnyKernel3/tools/ak3-core.sh`, `ak3-custom.sh`, `busybox`, `magiskboot` (+ extra tools)
- `modules/`, `ramdisk/`, `patch/` dirs **removed** (not needed)

### Current Configuration ✅ (already done)
The `AnyKernel3/anykernel.sh` has been customized for veux:

- **Device names:** `device.name1=veux`, `device.name2=peux` (correct for this kernel project)
- **Block device:** `BLOCK=boot` for boot section, `BLOCK=vendor_boot` for vendor_boot section
- **Slot device:** `IS_SLOT_DEVICE=auto` for boot, vendor_boot section uses `reset_ak` + `split_boot` + `flash_boot`
- **Install sections:** boot (`split_boot` + `flash_boot`), vendor_boot (`reset_ak` + `split_boot` + `check_cmdline` + `check_vendor_hals` + `flash_boot`), dtbo (`erase_dtbo`)
- **Kernel string:** `kernel.string=nebula kernel by frost` ( banner shows "ResuKiSU veux kernel")
- **Modules:** `do.modules` not set in properties (modules staged but not auto-pushed unless added)

---

## Build Script Invocation Modes

```bash
./buildveuxv2.sh            # Full clean build (make mrproper + veux_defconfig + build + AK3 zip)
./buildveuxv2.sh --resume   # Incremental (skip mrproper + defconfig)
./buildveuxv2.sh --check    # Verify KSU hooks in existing Image (no build)
```

### Environment Overrides
| Variable | Default | Notes |
|----------|---------|-------|
| `TC_PATH` | autodetect (`~/toolchains/clang-r596125/bin`) | dir with clang + ld.lld + llvm-ar |
| `JOBS` | `nproc` | parallel build jobs |
| `KCFLAGS` | `-O2 -fvisibility=hidden -mcpu=cortex-a76` | C compiler flags |
| `KCPPFLAGS` | `-O2` | C++ preprocessor flags |
| `CROSS_COMPILE` | `aarch64-linux-gnu-` | cross-compiler prefix |
| `KSU_FIX` | `1` | auto-append KALLSYMS_ALL (set 0 to disable) |
| `LTO_THIN` | `1` | enable ThinLTO (set 0 for full LTO) |
| `BOLT` | auto | 0 to disable BOLT (auto if llvm-bolt found) |
| `MLGO_MODEL` | `~/mlgo-model.mlgo` if exists | MLGO inlining model path |
| `PROFILE_GEN` | `1` (PGO ON by default) | 1 = instrumented build for PGO phase 1; set 0 to disable PGO |
| `PROFILE_USE` | unset | path to profile data for PGO phase 2 (use after a PROFILE_GEN=1 run) |
| `LOG_FILE` | `./error.log` | build log path |
| `OUT_DIR` | `/mnt/c/Users/Administrator/Documents/out` | AK3 zip destination |

---

## Build Pipeline (Step by Step)

1. Parse args (`--resume` / `--check`)
2. Detect `TC_PATH` (clang-r596125 → system LLVM fallback)
3. Export `PATH="$TC_PATH:$PATH"`, set `ARCH=arm64`, `CROSS_COMPILE`, `LLVM=1`, `LLVM_IAS=1`
4. Set `JOBS`, `KCFLAGS`, `KCPPFLAGS`, `LOG_FILE`, `OUT_DIR`, `IMAGE`, `IMAGE_GZ`, `VMLINUX`
5. Optional: MLGO auto-detect
6. Optional: BOLT auto-enable
7. Define `KSU_SYMBOLS` array (6 symbols)
8. If `--check`: run `check_ksu_symbols` on `$IMAGE` and exit
9. If not resume: `make mrproper` (removes .config) + `make veux_defconfig` (fresh from defconfig)
10. If `CONFIG_KSU=y` && `!CONFIG_KALLSYMS_ALL`: append fix to `.config`
11. If `CONFIG_LTO_CLANG=y` && `# CONFIG_THINLTO is not set`: enable ThinLTO
12. `make olddefconfig` (reconcile, non-interactive)
13. Build `KBUILD_CFLAGS` base: `-fno-builtin-wcslen -fno-strict-overflow -fno-merge-all-constants -ffunction-sections -fdata-sections`
14. `KBUILD_LDFLAGS` base: `-gc-sections`
15. PGO is ON by default (`PROFILE_GEN=1`). Add `-fprofile-generate` to both CFLAGS and LDFLAGS for a profile-generation (phase 1) build.
16. If `PROFILE_USE` is set (phase 2, after collecting profile data from a phase-1 run): add `-fprofile-use=$PROFILE_USE` to both CFLAGS and LDFLAGS.
17. To disable PGO entirely: run with `PROFILE_GEN=0`.
17. If `MLGO_MODEL` set: add `-fmlgo-inlining=$MLGO_MODEL` to `KBUILD_CFLAGS`
18. Export `KBUILD_CFLAGS`, `KBUILD_LDFLAGS`
19. Determine targets: `Image Image.gz dtbs` [+ `modules` if `CONFIG_MODULES=y`]
20. `make -j$JOBS KCFLAGS="$KCFLAGS $KBUILD_CFLAGS" KCPPFLAGS="$KCPPFLAGS" LDFLAGS="$KBUILD_LDFLAGS" $TARGETS`
21. `check_ksu_symbols` on built Image
22. Copy artifacts: `Image` → `$ROOT/Image`, `Image.gz` → `$ROOT/Image.gz`, dtbs → `$ROOT/dtbs/`
23. If `BOLT_ENABLE=1`: post-link BOLT optimization on vmlinux → regenerate Image/Image.gz
24. If `AnyKernel3/` exists: stage into `/tmp/ak3_stage/` (cp -r AnyKernel3/.), copy Image.gz, modules/*.ko; **dtb/ directory staging is skipped** — AnyKernel3/dtb is the single veux DTB blob and is preserved as-is in the zip. Zip to `/tmp/$ZIP`, copy to `$OUT_DIR` or `$ROOT`.

---

## AnyKernel3 Packaging Notes

### What gets into the zip
- `AnyKernel3/` tree (anykernel.sh, META-INF/, tools/, banner, cmdline, dtb blob)
- `Image.gz` (compressed kernel, staged from `arch/arm64/boot/Image.gz`)
- `modules/*.ko` (built modules, if `CONFIG_MODULES=y`; staged but not auto-pushed unless `do.modules=1` is set in `anykernel.sh` properties)
- `dtb/` directory staging is **skipped** — `AnyKernel3/dtb` is the single veux DTB blob and is preserved as-is

### Current `anykernel.sh` configuration (already done)
```bash
properties() { '
kernel.string=nebula kernel by frost
do.devicecheck=1
do.cleanup=1
device.name1=veux
device.name2=peux
'; } # end properties
```

Install sections:
- **boot:** `split_boot` + `flash_boot` (BLOCK=boot, IS_SLOT_DEVICE=auto)
- **vendor_boot:** `reset_ak` + `split_boot` + `check_cmdline` + `check_vendor_hals` + `flash_boot` (BLOCK=vendor_boot)
- **dtbo:** `erase_dtbo`

### Banner and cmdline
- `banner` — ASCII logo + "ResuKiSU veux kernel" (copied from `nebula-veux/banner`, edited)
- `cmdline` — veux bootargs (copied from `nebula-veux/cmdline`): `androidboot.hardware=qcom`, `androidboot.init_fatal_reboot_target=recovery`, `lpm_levels.sleep_disabled=1`, `service_locator.enable=1`, `androidboot.usbcontroller=4e00000.dwc3`, `swiotlb=noforce`, `loop.max_part=7`, `iptable_raw.raw_before_defrag=1`, `ip6table_raw.raw_before_defrag=1`, `buildvariant=user`

### Removed from AnyKernel3/
- `modules/` — removed (populated at zip time by build script from built .ko files)
- `ramdisk/` — removed (placeholder, not needed)
- `patch/` — removed (placeholder, not needed)

---

## Known Issues / To-Do

- [ ] Verify full build + AK3 zip chain end-to-end (first run with `make mrproper` + PGO phase 1)
- [ ] Collect PGO profile data from phase-1 build and run phase-2 with `PROFILE_USE=<path>` for optimized binary
- [ ] Consider adding pre-build validation of AnyKernel3 contents (check for `anykernel.sh`, `META-INF/`, `tools/ak3-core.sh`, `banner`, `cmdline`, `dtb`)
- [ ] Consider adding ccache support (CI has it, local script doesn't)
- [ ] Consider adding disk space check before build (LLVM toolchain ~12GB)
- [ ] Decide whether to set `do.modules=1` in `anykernel.sh` properties if .ko auto-push is wanted

---

## File Inventory

| File | Purpose |
|------|---------|
| `buildveuxv2.sh` | Main build script (audited, corrections applied) |
| `applyreuki.sh` | ReSukiSU hook injector (fs/exec.c, fs/stat.c, kernel/reboot.c) |
| `build_veux.sh` | Previous build script (reference for comparison) |
| `AnyKernel3/` | AnyKernel3 folder, customized for veux (banner, cmdline, dtb blob, anykernel.sh with boot+vendor_boot+dtbo) |
| `AnyKernel3/META-INF/` | ZIP metadata (update-binary + updater-script) |
| `AnyKernel3/tools/` | AK3 backend tools (ak3-core.sh, magiskboot, busybox) |
| `.github/workflows/build-veux.yml` | CI pipeline (LLVM 23.1.0, ccache, reference) |
| `~/toolchains/clang-r596125/` | LLVM toolchain (Clang 22.0.2, +PGO +BOLT +LTO +MLGO) |
| `/mnt/c/Users/Administrator/Documents/out/` | AK3 zip output directory (Windows mount) |
