#!/bin/sh
# Fetches WordCraft at a fixed commit into engine/vendor/wordcraft and applies the small change
# HayDocs needs: on iOS the engine reads the system fonts from /System/Library/Fonts, as on macOS
# (upstream treats every other Unix as Linux). Also makes engine/vendor/craft-doc-binary, the
# Word 97-2003 reader from craft-libs with patches/craft-doc-binary.patch (table cell borders
# and widths), which Cargo.toml puts in place of craft-libs' own.
set -eu
REV=4d7100a7f8ad39d4ccdb22311fa89db8e0ccfc6a
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/vendor/wordcraft"

if [ -L "$DEST" ]; then
    echo "vendor/wordcraft is a link (local checkout), leaving it as it is"
else
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
fi

# Made again only when the patch changes, so Cargo keeps its build of it.
CRAFT_REV=b436ae992591173ce53fdb1314421ba2d8897e49
DOCBIN="$HERE/vendor/craft-doc-binary"
PATCH="$HERE/patches/craft-doc-binary.patch"
STAMP="$CRAFT_REV $(cksum < "$PATCH" | awk '{print $1, $2}')"
if [ "$(cat "$DOCBIN/.haydocs-stamp" 2>/dev/null)" != "$STAMP" ]; then
    SRC="$HERE/vendor/craft-libs-src"
    rm -rf "$DOCBIN" "$SRC"
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin https://github.com/storytold/craft-libs.git
    git -C "$SRC" config core.sparseCheckout true
    echo "crates/doc-binary/" > "$SRC/.git/info/sparse-checkout"
    git -C "$SRC" fetch -q --depth 1 --filter=blob:none origin "$CRAFT_REV"
    git -C "$SRC" checkout -q FETCH_HEAD
    cp -R "$SRC/crates/doc-binary" "$DOCBIN"
    rm -rf "$SRC"
    (cd "$DOCBIN" && patch -s -p1 < "$PATCH")
    echo "$STAMP" > "$DOCBIN/.haydocs-stamp"
fi
grep -q "T_SET_BRC" "$DOCBIN/src/table.rs" || { echo "craft-doc-binary patch did not apply" >&2; exit 1; }
echo "craft-doc-binary ready in $DOCBIN"
