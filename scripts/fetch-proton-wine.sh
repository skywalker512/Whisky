#!/usr/bin/env bash
#
# Lay down vendor/proton-wine at the pinned Valve bleeding-edge base that
# patches/proton-wine/* apply against. The tree is gitignored (not a submodule),
# so a fresh clone / CI runner needs this before `make proton`.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Keep in sync with docs/proton-migration.md ("Base: c3007e6f on bleeding-edge").
PROTON_WINE_BASE="${PROTON_WINE_BASE:-c3007e6f2a36914cc55301eb5efd067707bf8bb1}"
PROTON_WINE_URL="${PROTON_WINE_URL:-https://github.com/ValveSoftware/wine.git}"
WINE_SRC="${WINE_SRC:-$PROJECT_DIR/vendor/proton-wine}"

if [ -d "$WINE_SRC/.git" ]; then
    cur="$(git -C "$WINE_SRC" rev-parse HEAD 2>/dev/null || true)"
    if [ "$cur" = "$PROTON_WINE_BASE" ] || git -C "$WINE_SRC" merge-base --is-ancestor "$PROTON_WINE_BASE" HEAD 2>/dev/null; then
        # Already have the base (or a descendant / patch branch). Ensure the
        # whisky/base ref exists for proton-branch.sh, then leave the tree alone.
        if ! git -C "$WINE_SRC" rev-parse --verify "$WHISKY_PATCH_BASE" >/dev/null 2>&1; then
            git -C "$WINE_SRC" tag -f "$WHISKY_PATCH_BASE" "$PROTON_WINE_BASE" 2>/dev/null \
                || git -C "$WINE_SRC" branch -f "$WHISKY_PATCH_BASE" "$PROTON_WINE_BASE"
        fi
        echo "=== proton-wine already present at $(git -C "$WINE_SRC" rev-parse --short HEAD) ==="
        exit 0
    fi
fi

echo "=== Fetching proton-wine base $PROTON_WINE_BASE ==="
rm -rf "$WINE_SRC"
mkdir -p "$(dirname "$WINE_SRC")"
git clone --filter=blob:none --no-checkout "$PROTON_WINE_URL" "$WINE_SRC"
git -C "$WINE_SRC" fetch --depth 1 origin "$PROTON_WINE_BASE"
git -C "$WINE_SRC" checkout --force FETCH_HEAD
# Named ref for scripts/proton-branch.sh / apply_patches documentation.
git -C "$WINE_SRC" branch -f "$WHISKY_PATCH_BASE" HEAD
echo "=== proton-wine ready: $(git -C "$WINE_SRC" rev-parse --short HEAD) ==="
