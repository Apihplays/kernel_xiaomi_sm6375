# veux Kernel Build Guide

## Device Info

| Property | Value |
|---|---|
| Device | Redmi Note 11 Pro 5G |
| Codename | veux |
| SoC | Qualcomm SM6375 (Holi) - Snapdragon 695 5G |
| Kernel | Linux 5.4.302 |
| Build type | QGKI (monolithic, not GKI 2.0) |
| KernelSU | XXKSU (backslashxx fork, compiled in-tree) |

## Requirements

- **Toolchain**: Clang 22.1.2 at `$HOME/Clang/LLVM-22.1.2-Linux-X64/bin/`
- **No GCC needed** — pure LLVM build (`LLVM=1 LLVM_IAS=1`)
- **openSUSE Tumbleweed** — see [Tumbleweed Notes](#tumbleweed-notes) for distro-specific issues

## Build Commands

### 1. Generate .config

```bash
./gen_.config.sh
```

Or manually:
```bash
export PATH=$HOME/Clang/LLVM-22.1.2-Linux-X64/bin:$PATH
export LD_LIBRARY_PATH=$HOME/Clang/LLVM-22.1.2-Linux-X64/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

make ARCH=arm64 O=out LLVM=1 LLVM_IAS=1 veux_defconfig
```

### 2. Build Kernel

```bash
./build_kernel.sh
```

Or manually:
```bash
make -j$(nproc --all) ARCH=arm64 O=out LLVM=1 LLVM_IAS=1 2>&1 | tee build.log
```

### 3. Package Flashable Zip

```bash
./package_kernel.sh
```

Output: `XXKSU-veux-YYYYMMDD.zip`

### Full Workflow

```bash
./gen_.config.sh && ./build_kernel.sh && ./package_kernel.sh
```

## Key Defconfig Changes

In `arch/arm64/configs/veux_defconfig`:

```
CONFIG_KSU=y                    # XXKSU compiled in-tree
CONFIG_KSU_MANUAL_HOOK=y        # (legacy, ignored by XXKSU Kconfig)
CONFIG_KALLSYMS=y               # Required for XXKSU
CONFIG_KALLSYMS_ALL=y           # Required for XXKSU
CONFIG_THINLTO=y                # Changed from Full LTO (8GB RAM friendly)
CONFIG_LTO_CLANG=y              # Required for LTO
CONFIG_SM_GPUCC_HOLI=y          # GPU clock controller for Holi SoC (SM6375)
CONFIG_QCOM_KGSL_IDLE_TIMEOUT=80
```

### Critical GPU Fix (2026-08-23)

The original defconfig was missing `CONFIG_SM_GPUCC_HOLI=y`. Without it, the GPU clock
controller driver doesn't load, causing:

- 870+ GPU resets
- GPU locked at 266MHz (minimum) by TrustZone governor
- Apps rendering blank screens / Chrome never finishing loads

The fix adds `CONFIG_SM_GPUCC_HOLI=y` along with related KGSL configs. This is the
**most important config change** for this device — without it, the GPU is unusable.

Other missing configs added:
- `CONFIG_QCOM_KGSL_IDLE_TIMEOUT=80` — GPU idle timeout
- `CONFIG_QCOM_KGSL_CONTEXT_DEBUG=y` — GPU context debugging
- `CONFIG_GKI_HIDDEN_*` — Display/audio/GPU configs needed by Android framework

### Why ThinLTO?

Full LTO is single-threaded during linking and uses 4-6GB+ RAM. On 8GB RAM this causes
massive swap thrashing. ThinLTO parallelizes linking across all cores and uses ~1-2GB per
thread. Slight binary size increase but build time drops from 15-30min to 3-8min for the
link step alone.

## Kernel Image Format

This device uses **raw Image + separate DTB** (NOT Image.gz-dtb):

| File | Description |
|---|---|
| `Image` | Uncompressed kernel (~30MB) |
| `veux.dtb` | Device tree blob (~384K) |
| `veux-overlay.dtbo` | DT overlay (323 bytes) |

The defconfig has:
```
CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL=y
CONFIG_BUILD_ARM64_DT_OVERLAY=y
```

## Packaging Format (AnyKernel3)

Matches the stock positron kernel format. See [Stock Kernel Analysis](#stock-kernel-analysis).

### Zip Contents

| File | Source | Purpose |
|---|---|---|
| `Image` | Build output | Raw kernel (NOT gzipped) |
| `dtb` | Build output | Renamed from `veux.dtb` |
| `cmdline` | Copied from stock | Kernel command line injection |
| `anykernel.sh` | Custom | Flash script for veux |
| `tools/ak3-custom.sh` | Copied from stock | DTB patching, vendor_boot, dtbo erasure |
| `tools/fdtput` | Copied from stock | Device tree manipulation |
| `tools/bspatch` | Copied from stock | Binary patch tool |

### What ak3-custom.sh Does

1. **`check_cmdline()`** — Injects custom cmdline into boot image header
2. **`check_vendor_hals()`** — Detects stock vendor HALs and patches DTB at flash time:
   - Audio codec (aw88261, fs1962)
   - Display dimensions (695x1546)
   - NFC chip (pn553 → pn557)
   - IR blower (ir-spi-xiaomi)
3. **`check_twrp()`** — Optionally disables TWRP recovery
4. **`erase_dtbo()`** — Zeros out dtbo partition to prevent DT conflicts

### Flash Script Flow

```
anykernel.sh:
  split_boot          # Unpack boot.img
  flash_boot           # Repack and flash boot

  reset_ak             # Switch to vendor_boot
  split_boot           # Unpack vendor_boot
  check_cmdline        # Inject cmdline
  check_twrp           # Handle TWRP
  check_vendor_hals    # Patch DTB for vendor compatibility
  flash_boot           # Repack and flash vendor_boot

  erase_dtbo           # Zero dtbo partition
```

### What We Don't Include (vs stock positron)

- `ksu.bdf` — Runtime KernelSU binary patch (we compile XXKSU in-tree instead)
- `KSU_UNLOCK` — Marker file to trigger bspatch (not needed)

## Stock Kernel Analysis (positron-veux-20260613.zip)

Reference kernel by "dereference" used as packaging template.

### Stock zip vs Our zip

| | Stock (positron) | Our (XXKSU) |
|---|---|---|
| Kernel | `Image` (48MB, raw) | `Image` (30MB, raw) |
| DTB | `dtb` (389K) | `dtb` (389K) |
| cmdline | 279 bytes | 279 bytes (same) |
| KSU | `ksu.bdf` + `bspatch` | Compiled in (`CONFIG_KSU=y`) |
| vendor_boot | Patches it | Patches it |
| dtbo | Erases partition | Erases partition |
| DTB patching | Live vendor HAL detection | Same (`ak3-custom.sh`) |

### Why stock Image is bigger (48MB vs 30MB)

Stock positron likely has more drivers compiled as built-in (=y) vs our config which
may have some as modules or disabled. The XXKSU version also differs — stock uses
runtime binary patching, we compile it in-tree.

## Tumbleweed Notes

### libxml2.so.2 Missing

Clang's `ld.lld` requires `libxml2.so.2`. Tumbleweed ships `libxml2.so.16` (libxml2 2.15+).
No compat package exists.

**Fix**: Symlink in Clang's lib directory:
```bash
ln -sf /usr/lib64/libxml2.so.16 $HOME/Clang/LLVM-22.1.2-Linux-X64/lib/libxml2.so.2
```

Then set `LD_LIBRARY_PATH` in your build scripts:
```bash
export LD_LIBRARY_PATH=$HOME/Clang/LLVM-22.1.2-Linux-X64/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
```

This produces harmless warnings ("no version information available") but works correctly.

### zip Not Installed

openSUSE Tumbleweed doesn't install `zip` by default:
```bash
sudo zypper install zip
```

## Hardware

- **CPU**: Ryzen 5500 (6C/12T)
- **RAM**: 8GB + 32GB swap
- **Build time**: ~10-15 minutes with ThinLTO

## File Structure

```
kernel_veux/
├── arch/arm64/configs/
│   ├── veux_defconfig              # Main defconfig (consolidated, self-contained)
│   ├── gki_defconfig               # Base GKI defconfig (NOT used for veux)
│   └── vendor/
│       ├── holi_QGKI.config        # SoC QGKI fragment (already in veux_defconfig)
│       ├── holi_GKI.config         # SoC GKI fragment (NOT used)
│       └── ...
├── drivers/kernelsu/               # Symlink → ../KernelSU/kernel (XXKSU)
├── KernelSU/                       # XXKSU source (backslashxx fork)
├── AnyKernel3/                     # Flashable zip template
│   ├── anykernel.sh                # Custom for veux
│   ├── cmdline                     # Kernel command line
│   └── tools/
│       ├── ak3-custom.sh           # DTB patching, vendor_boot, dtbo
│       ├── fdtput                  # Device tree tool
│       └── bspatch                 # Binary patch tool
├── gen_.config.sh                  # Generate .config
├── build_kernel.sh                 # Build kernel
├── package_kernel.sh               # Package flashable zip
├── setup_xxksu.sh                  # Setup XXKSU (already run)
└── BUILD_GUIDE.md                  # This file
```
