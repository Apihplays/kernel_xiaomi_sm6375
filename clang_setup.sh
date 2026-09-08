#!/bin/bash
# ========================================================================
# setup_clang.sh – Symlink Clang/LLVM toolchain for kernel building
# ========================================================================
# This script links the required LLVM tools from:
#   /home/hayyan/toolchains/clang-r596125/bin/
# into ~/bin (which is added to PATH) so that the kernel build uses them.
#
# The build script (build_veux.sh) already auto-detects this toolchain and
# enables ThinLTO, MLGO, PGO (when profile provided), and BOLT automatically.
#
# Tools symlinked:
#   Compiler: clang, clang++
#   Linker: ld.lld
#   Binutils: llvm-ar, llvm-nm, llvm-objcopy, llvm-objdump, llvm-readelf, llvm-strip
#   LTO helpers: llvm-link, llvm-dis
#   Optimizations: llvm-bolt, llvm-profdata
#
# Usage:
#   ./setup_clang.sh          -> DRY-RUN (preview only, no changes)
#   ./setup_clang.sh --apply  -> Actually create symlinks
# ========================================================================

set -euo pipefail

# --- Configuration ----------------------------------------------------
CLANG_SRC="/home/hayyan/toolchains/clang-r596125/bin"
TARGET_DIR="$HOME/bin"
TOOLS=(
    # Compiler
    "clang"
    "clang++"
    # Linker
    "ld.lld"
    # LLVM binutils (used by kernel build)
    "llvm-ar"
    "llvm-nm"
    "llvm-objcopy"
    "llvm-objdump"
    "llvm-readelf"
    "llvm-strip"
    # LTO / ThinLTO helpers
    "llvm-link"
    "llvm-dis"
    # Advanced optimizations (BOLT, PGO)
    "llvm-bolt"
    "llvm-profdata"
)
# --------------------------------------------------------------------

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Audit check: source directory exists ----------------------------
if [ ! -d "$CLANG_SRC" ]; then
    echo -e "${RED}ERROR: Clang source directory not found: $CLANG_SRC${NC}"
    echo "Please verify the path is correct."
    exit 1
fi

# --- Create target directory if missing -------------------------------
mkdir -p "$TARGET_DIR"

# --- Determine mode (dry-run vs apply) -------------------------------
APPLY=false
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=true
fi

# --- Dry-run: show what will be done ---------------------------------
echo -e "${YELLOW}>>> DRY-RUN MODE (preview only)${NC}"
echo "Source directory : $CLANG_SRC"
echo "Target directory : $TARGET_DIR"
echo "Tools to be symlinked:"
for tool in "${TOOLS[@]}"; do
    src="$CLANG_SRC/$tool"
    dst="$TARGET_DIR/$tool"
    if [ -f "$src" ]; then
        if [ -L "$dst" ] || [ -e "$dst" ]; then
            echo "  [UPDATE] $dst -> $src"
        else
            echo "  [NEW]    $dst -> $src"
        fi
    else
        echo -e "${RED}  [MISSING] $src (will be skipped)${NC}"
    fi
done

echo ""
echo -e "${YELLOW}>>> Recommended PATH addition:${NC}"
echo "export PATH=\"$TARGET_DIR:\$PATH\""
echo ""

if [ "$APPLY" = false ]; then
    echo -e "${YELLOW}This was a DRY-RUN. No changes were made.${NC}"
    echo "To apply, run: $0 --apply"
    exit 0
fi

# --- Apply mode: create symlinks -------------------------------------
echo -e "${GREEN}>>> APPLY MODE: Creating symlinks...${NC}"
for tool in "${TOOLS[@]}"; do
    src="$CLANG_SRC/$tool"
    dst="$TARGET_DIR/$tool"
    if [ ! -f "$src" ]; then
        echo -e "${RED}[SKIP] Source missing: $src${NC}"
        continue
    fi
    # Remove existing file/dir/symlink at destination (force replace)
    if [ -L "$dst" ] || [ -e "$dst" ]; then
        rm -f "$dst"
    fi
    ln -s "$src" "$dst"
    echo -e "${GREEN}[DONE] $dst -> $src${NC}"
done

echo ""
echo -e "${GREEN}>>> Symlinking complete.${NC}"
echo "Please add the following line to your ~/.bashrc or ~/.zshrc:"
echo -e "${YELLOW}export PATH=\"$TARGET_DIR:\$PATH\"${NC}"
echo "Then run: source ~/.bashrc  (or source ~/.zshrc)"
echo ""
echo -e "After that, your build script (build_veux.sh) will automatically"
echo "detect this Clang toolchain and enable:"
echo "  - ThinLTO (default)"
echo "  - BOLT (auto-detects llvm-bolt)"
echo "  - MLGO (if model file exists at ~/mlgo-model.mlgo)"
echo "  - PGO (when you set PROFILE_GEN=1 or PROFILE_USE=...)"
echo ""
echo "To verify the toolchain is working, run:"
echo "  clang --version && llvm-bolt --version | head -1"
