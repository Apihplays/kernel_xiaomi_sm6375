#!/bin/bash
# build_and_release.sh - one-command kernel build + GitHub release
#
#  1. remove ALL prior ksun-veux-*.zip (so only one remains)
#  2. clean build  (./build_kernel.sh clean)
#  3. package flashable zip (./package_kernel.sh)
#  4. create a GitHub Release with the new zip as a downloadable asset
#
# GitHub release is best-effort:
#   - uses `gh` if authenticated,
#   - else uses the GitHub API via GITHUB_TOKEN / GH_PAT,
#   - else prints a SKIP message and exits 0 (zip is already built+packaged).
#
# Usage: ./build_and_release.sh
set -euo pipefail

# ── Locate repo root (this script lives in the repo root) ──────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Banner ─────────────────────────────────────────────────────
echo "=============================================================="
echo "  ksun / veux  -  build + package + GitHub release"
echo "  Repo : $REPO_ROOT"
echo "  Date : $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

# ── Toolchain (same as build_kernel.sh) ────────────────────────
export PATH="$HOME/Clang/LLVM-22.1.2-Linux-X64/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/Clang/LLVM-22.1.2-Linux-X64/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ── Step 1: remove old ksun zips ───────────────────────────────
echo "[1/4] Removing prior ksun-veux-*.zip files..."
mapfile -t OLD_ZIPS < <(ls -t "$REPO_ROOT"/ksun-veux-*.zip 2>/dev/null || true)
OLD_COUNT=${#OLD_ZIPS[@]}
rm -f "$REPO_ROOT"/ksun-veux-*.zip
echo "[+] Removed $OLD_COUNT old zip(s). Only the freshly built zip will remain."

# ── Step 2: clean build ────────────────────────────────────────
echo "[2/4] Clean build (./build_kernel.sh clean)..."
if ! ./build_kernel.sh clean; then
    echo "[FATAL] build_kernel.sh clean failed (exit $?)" >&2
    exit 1
fi
echo "[+] Build finished."

# ── Step 3: package flashable zip ──────────────────────────────
echo "[3/4] Packaging flashable zip (./package_kernel.sh)..."
if ! ./package_kernel.sh; then
    echo "[FATAL] package_kernel.sh failed (exit $?)" >&2
    exit 1
fi

# ── Capture the NEW zip (the only ksun-veux-*.zip left) ────────
NEW_ZIP="$(ls -t "$REPO_ROOT"/ksun-veux-*.zip 2>/dev/null | head -1)"
if [ -z "$NEW_ZIP" ] || [ ! -f "$NEW_ZIP" ]; then
    echo "[FATAL] package_kernel.sh ran but no ksun-veux-*.zip was produced." >&2
    exit 1
fi
echo "[+] New zip: $NEW_ZIP ($(du -h "$NEW_ZIP" | cut -f1))"

# Derive a unique tag + human-readable date stamp from the zip name.
#   ksun-veux-20260828-212139.zip  ->  DATE_STAMP=20260828-212139
ZIP_BASENAME="$(basename "$NEW_ZIP" .zip)"
DATE_STAMP="${ZIP_BASENAME#ksun-veux-}"
TAG="ksun-${DATE_STAMP}"
TITLE="ksun ${DATE_STAMP} (lean-KSU test build)"

# Kernel uname string for the release body.
KNAME="$(strings out/arch/arm64/boot/Image 2>/dev/null | grep -m1 '5.4.302' || true)"

# ── Step 4: create GitHub Release (best-effort) ────────────────
echo "[4/4] Creating GitHub Release..."

BODY=$(cat <<EOF
TEST BUILD - for soft-reboot validation on device.

This is a pre-release / test build. Flash at your own risk and validate
system_server stability / soft-reboot behavior on the phone.

Kernel : ${KNAME:-5.4.302-ksun (uname string not extracted)}
Branch : ksun
Asset  : $(basename "$NEW_ZIP")
EOF
)

REPO="Apihplays/kernel_xiaomi_sm6375"

# Guard against a non-unique tag (same-minute re-run / leftover tag from a
# failed run). With `set -e` a "tag already exists" error from `gh` would abort
# the whole script even though the zip built fine. Make the tag unique, and if
# a release with that tag already exists, skip creation instead of failing.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "[*] Release $TAG already exists — skipping creation (zip is ready at $NEW_ZIP)."
    echo "[+] Existing release: https://github.com/$REPO/releases/tag/$TAG"
else
    SUFFIX=0
    CANDIDATE="$TAG"
    while gh release view "$CANDIDATE" --repo "$REPO" >/dev/null 2>&1; do
        SUFFIX=$((SUFFIX + 1))
        CANDIDATE="${TAG}-${SUFFIX}"
    done
    TAG="$CANDIDATE"

    if gh auth status >/dev/null 2>&1; then
        echo "[+] gh is authenticated -> using 'gh release create'."
        gh release create "$TAG" "$NEW_ZIP" \
            --repo "$REPO" \
            --title "$TITLE" \
            --notes "$BODY" \
            --prerelease \
            --target ksun
        echo "[+] Release created: https://github.com/$REPO/releases/tag/$TAG"

    elif [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_PAT:-}" ]; then
        TOKEN="${GITHUB_TOKEN:-${GH_PAT:-}}"
        echo "[+] Token present (GITHUB_TOKEN/GH_PAT) -> using GitHub API (curl)."
        RESP="$(curl -sS -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -d "$(jq -n \
                    --arg tag "$TAG" \
                    --arg title "$TITLE" \
                    --arg body "$BODY" \
                    --arg target "ksun" \
                    '{tag_name:$tag, name:$title, body:$body, prerelease:true, target_commitish:$target}')" \
            "https://api.github.com/repos/$REPO/releases")"

        UPLOAD_URL="$(printf '%s' "$RESP" | jq -r '.upload_url // empty' | sed 's/{?name,label}$//')"
        if [ -z "$UPLOAD_URL" ]; then
            echo "[WARN] Release creation returned no upload_url. Response:" >&2
            printf '%s\n' "$RESP" | jq -r '.message // empty' >&2 || true
        else
            ASSET_NAME="$(basename "$NEW_ZIP")"
            curl -sS -X POST \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/zip" \
                --data-binary @"$NEW_ZIP" \
                "${UPLOAD_URL}?name=${ASSET_NAME}"
            echo "[+] Asset uploaded: $ASSET_NAME"
            echo "[+] Release created: https://github.com/$REPO/releases/tag/$TAG"
        fi

    else
        echo "Release upload SKIPPED (no gh auth / no GITHUB_TOKEN). Zip is ready at $NEW_ZIP. Upload manually or set GH_PAT."
        exit 0
    fi
fi

echo "=============================================================="
echo "[DONE] Build + package complete; release published."
echo "  Zip : $NEW_ZIP"
echo "  Tag : $TAG"
echo "=============================================================="
