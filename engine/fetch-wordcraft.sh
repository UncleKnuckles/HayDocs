#!/bin/sh
# Fetches WordCraft at a fixed commit into engine/vendor/wordcraft and applies the small change
# HayDocs needs: on iOS the engine reads the system fonts from /System/Library/Fonts, as on macOS
# (upstream treats every other Unix as Linux).
set -eu
REV=4d7100a7f8ad39d4ccdb22311fa89db8e0ccfc6a
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/vendor/wordcraft"

if [ -L "$DEST" ]; then
    echo "vendor/wordcraft is a link (local checkout), leaving it as it is"
    exit 0
fi
if [ ! -d "$DEST/.git" ] || [ "$(git -C "$DEST" rev-parse HEAD 2>/dev/null)" != "$REV" ]; then
    rm -rf "$DEST"
    mkdir -p "$DEST"
    git -C "$DEST" init -q
    git -C "$DEST" remote add origin https://github.com/storytold/wordcraft.git
    git -C "$DEST" fetch -q --depth 1 origin "$REV"
    git -C "$DEST" checkout -q FETCH_HEAD
fi

NAMES="$DEST/crates/fonts/src/fontdb/names.rs"
if ! grep -q 'target_os = "ios"' "$NAMES"; then
    sed -i.bak 's/if cfg!(target_os = "macos") {/if cfg!(any(target_os = "macos", target_os = "ios")) {/' "$NAMES"
    rm -f "$NAMES.bak"
fi
grep -q 'any(target_os = "macos", target_os = "ios")' "$NAMES" || { echo "iOS font folder patch did not apply" >&2; exit 1; }
echo "WordCraft $REV ready in $DEST"
