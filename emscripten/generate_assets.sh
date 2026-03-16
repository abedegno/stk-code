#!/bin/bash
#
# generate_assets.sh — Prepare STK game assets for browser delivery
#
# Usage:
#   generate_assets.sh <stk-assets-dir> <output-dir> [<texture-size>]
#
# Arguments:
#   <stk-assets-dir>   Path to the stk-assets repository
#   <output-dir>       Directory where archives and manifests are written
#   <texture-size>     Max texture dimension in pixels (default: from ASSET_QUALITY)
#
# Environment:
#   ASSET_QUALITY      low (128px) | mid (256px) | high (original) | all
#                      Ignored if <texture-size> is provided explicitly.
#                      Defaults to "mid" when neither is set.
#
# Output per quality tier:
#   data_<quality>_core.tar.zst.00, .01, ...    core assets (no tracks)
#   data_<quality>_core.tar.zst.manifest
#   data_<quality>_tracks.tar.zst.00, .01, ...  track directories
#   data_<quality>_tracks.tar.zst.manifest
#
# Each manifest: first line = uncompressed archive size in bytes,
#                following lines = chunk filenames (basename only).

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STK_CODE_DIR="$(dirname "$SCRIPT_DIR")"

# ── Help ────────────────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage: generate_assets.sh <stk-assets-dir> <output-dir> [<texture-size>]

Arguments:
  <stk-assets-dir>   Path to the stk-assets repository
  <output-dir>       Directory where archives and manifests are written
  <texture-size>     Max texture dimension in pixels (default: from ASSET_QUALITY)

Environment:
  ASSET_QUALITY      low (128px) | mid (256px) | high (original) | all
                     Defaults to "mid" when neither is set.
  OPUS_BITRATE       Opus encoding bitrate in kbps (default: 24)
USAGE
    exit 0
}

case "${1-}" in
    --help|-h) usage ;;
esac

# ── Arguments ───────────────────────────────────────────────────────────────

ASSETS_DIR="${1:?Usage: generate_assets.sh <stk-assets-dir> <output-dir> [<texture-size>]}"
OUTPUT_DIR="${2:?Missing output directory}"
TEXTURE_SIZE_ARG="${3-}"   # optional; overrides ASSET_QUALITY when present

if [ ! -d "$ASSETS_DIR" ]; then
    echo "ERROR: stk-assets directory not found: $ASSETS_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ASSETS_DIR="$(cd "$ASSETS_DIR" && pwd)"

# ── Quality tiers ────────────────────────────────────────────────────────────

# Map quality label → texture size
quality_to_size() {
    case "$1" in
        low)  echo 128 ;;
        mid)  echo 256 ;;
        high) echo 0   ;;  # 0 = original resolution (no downscale)
        *) echo "ERROR: Unknown ASSET_QUALITY '$1'. Use: low | mid | high | all" >&2; exit 1 ;;
    esac
}

# Decide which tiers to build
if [ -n "$TEXTURE_SIZE_ARG" ]; then
    # Explicit numeric size → single unnamed tier, stored as "custom"
    TIERS="custom"
    TIER_SIZE_custom="$TEXTURE_SIZE_ARG"
elif [ -n "${ASSET_QUALITY-}" ]; then
    if [ "$ASSET_QUALITY" = "all" ]; then
        TIERS="low mid high"
        TIER_SIZE_low=128
        TIER_SIZE_mid=256
        TIER_SIZE_high=0
    else
        TIERS="$ASSET_QUALITY"
        sz="$(quality_to_size "$ASSET_QUALITY")"
        eval "TIER_SIZE_${ASSET_QUALITY}=$sz"
    fi
else
    TIERS="mid"
    TIER_SIZE_mid=256
fi

# ── convert_to_opus.sh ───────────────────────────────────────────────────────

OPUS_SCRIPT="$SCRIPT_DIR/convert_to_opus.sh"
OPUS_SOURCE="$STK_CODE_DIR/tools/convert_to_opus.sh"

if [ ! -f "$OPUS_SCRIPT" ]; then
    if [ -f "$OPUS_SOURCE" ]; then
        echo "==> Copying convert_to_opus.sh from tools/..."
        cp "$OPUS_SOURCE" "$OPUS_SCRIPT"
        chmod +x "$OPUS_SCRIPT"
    else
        echo "WARNING: convert_to_opus.sh not found at $OPUS_SOURCE — audio conversion will be skipped"
        OPUS_SCRIPT=""
    fi
fi

# ── Helper: portable job count ───────────────────────────────────────────────

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

# ── Helper: create manifest ──────────────────────────────────────────────────

# create_manifest <archive-path>
# Writes <archive-path>.manifest alongside the archive.
# First line: uncompressed byte size of the archive.
# Subsequent lines: basename of each split chunk, sorted.
create_manifest() {
    local path="$1"
    local file_name
    file_name="$(basename "$path")"
    local data_dir
    data_dir="$(dirname "$path")"
    local size
    size="$(stat -f '%z' "$path" 2>/dev/null || stat --printf='%s' "$path")"

    {
        echo "$size"
        find "$data_dir" -name "${file_name}.[0-9]*" | sort | while read -r chunk; do
            basename "$chunk"
        done
    } > "${path}.manifest"
}

# ── Helper: build one quality tier ──────────────────────────────────────────

build_tier() {
    local tier="$1"
    local tex_size="$2"

    echo ""
    echo "=== Building tier: $tier (texture size: ${tex_size}px) ==="

    local WORK_DIR
    WORK_DIR="$(mktemp -d /tmp/stk-emscripten-assets-XXXXXX)"
    local DATA_DIR="$WORK_DIR/data"

    # ── 1. Run android/generate_assets.sh ──────────────────────────────────

    local GENERATE_SCRIPT="$STK_CODE_DIR/android/generate_assets.sh"

    if [ -f "$GENERATE_SCRIPT" ]; then
        echo "  -> Running android/generate_assets.sh (tex=${tex_size}px)..."
        export ASSETS_PATHS="$ASSETS_DIR"
        # Use an absolute OUTPUT_PATH — generate_assets.sh cd's to its own
        # directory, so relative paths would break.  The sed commands that
        # patch files.txt will fail harmlessly (files.txt is Android-only).
        export OUTPUT_PATH="$WORK_DIR"
        if [ "$tex_size" -gt 0 ] 2>/dev/null; then
            export TEXTURE_SIZE="$tex_size"
            export DECREASE_QUALITY=1
        else
            # high quality: copy at original resolution
            export TEXTURE_SIZE=9999
            export DECREASE_QUALITY=0
        fi
        chmod +x "$GENERATE_SCRIPT"
        "$GENERATE_SCRIPT" || {
            echo "  -> WARNING: generate_assets.sh had errors, falling back to direct copy..."
            mkdir -p "$DATA_DIR"
            rsync -a --quiet "$ASSETS_DIR/" "$DATA_DIR/"
            rsync -a --quiet "$STK_CODE_DIR/data/" "$DATA_DIR/"
        }
    else
        echo "  -> android/generate_assets.sh not found, copying assets directly..."
        mkdir -p "$DATA_DIR"
        rsync -a --quiet "$ASSETS_DIR/" "$DATA_DIR/"
        rsync -a --quiet "$STK_CODE_DIR/data/" "$DATA_DIR/"
    fi

    if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        echo "ERROR: $DATA_DIR is empty or missing after asset generation"
        rm -rf "$WORK_DIR"
        return 1
    fi

    # Run optimize_data.sh if present
    if [ -f "$DATA_DIR/optimize_data.sh" ]; then
        echo "  -> Optimizing assets..."
        chmod +x "$DATA_DIR/optimize_data.sh"
        (cd "$DATA_DIR" && ./optimize_data.sh) || echo "  -> optimize_data.sh had warnings (continuing)"
    fi

    # ── 2. Convert audio to Opus ────────────────────────────────────────────

    if [ -n "$OPUS_SCRIPT" ] && [ -f "$OPUS_SCRIPT" ]; then
        OGG_COUNT="$(find "$DATA_DIR" -name "*.ogg" | wc -l | tr -d ' ')"
        if [ "$OGG_COUNT" -gt 0 ]; then
            echo "  -> Converting $OGG_COUNT .ogg files to Opus (24kbps) via convert_to_opus.sh..."
            # convert_to_opus.sh expects the assets directory with music/ and sfx/
            # subdirectories.  We point it at DATA_DIR which mirrors that layout.
            bash "$OPUS_SCRIPT" "$DATA_DIR" --bitrate 24 || \
                echo "  -> WARNING: convert_to_opus.sh had errors (continuing)"
        else
            echo "  -> No .ogg files found to convert"
        fi
    else
        # Inline fallback: oggdec | opusenc
        OGG_COUNT="$(find "$DATA_DIR" -name "*.ogg" | wc -l | tr -d ' ')"
        if [ "$OGG_COUNT" -gt 0 ]; then
            echo "  -> Re-encoding $OGG_COUNT .ogg files to Opus 24kbps (inline)..."
            find "$DATA_DIR" -name "*.ogg" | while read -r f; do
                opus_out="${f%.ogg}.opus"
                if oggdec --quiet -o - "$f" 2>/dev/null | \
                        opusenc --quiet --bitrate 24 - "$opus_out" 2>/dev/null; then
                    rm "$f"
                else
                    echo "  -> WARNING: failed to re-encode $(basename "$f"), keeping original"
                    rm -f "$opus_out"
                fi
            done
            OPUS_COUNT="$(find "$DATA_DIR" -name "*.opus" | wc -l | tr -d ' ')"
            echo "  -> Re-encoded $OPUS_COUNT files to Opus"
            if [ "$OPUS_COUNT" -gt 0 ]; then
                echo "  -> Updating audio references (.ogg -> .opus) in XML/music files..."
                find "$DATA_DIR" \( -name "*.xml" -o -name "*.music" \) | while read -r f; do
                    if grep -q '\.ogg' "$f" 2>/dev/null; then
                        sed -i.bak 's/\.ogg/\.opus/g' "$f"
                        rm -f "${f}.bak"
                    fi
                done
            fi
        fi
    fi

    # ── 3. Create zstd archives (core + tracks) ─────────────────────────────

    local OUT_BASE="$OUTPUT_DIR/data_${tier}"
    local CORE_PATH="${OUT_BASE}_core.tar.zst"
    local TRACKS_PATH="${OUT_BASE}_tracks.tar.zst"

    # Remove stale chunks from previous runs
    rm -f "${CORE_PATH}"* "${TRACKS_PATH}"*

    echo "  -> Creating core archive (zstd -19)..."
    tar -cf - -C "$DATA_DIR" --exclude='./tracks' . | zstd -19 -T"$JOBS" -o "$CORE_PATH"

    echo "  -> Creating tracks archive (zstd -19)..."
    tar -cf - -C "$DATA_DIR" ./tracks | zstd -19 -T"$JOBS" -o "$TRACKS_PATH"

    # ── 4. Split into 20MB chunks ───────────────────────────────────────────

    echo "  -> Splitting archives into 20MB chunks..."
    split -b 20m --numeric-suffixes "$CORE_PATH"   "${CORE_PATH}."
    split -b 20m --numeric-suffixes "$TRACKS_PATH" "${TRACKS_PATH}."

    # ── 5. Generate manifests ───────────────────────────────────────────────

    create_manifest "$CORE_PATH"
    create_manifest "$TRACKS_PATH"

    # Remove the unsplit originals (chunks replace them)
    rm -f "$CORE_PATH" "$TRACKS_PATH"

    # ── Summary ─────────────────────────────────────────────────────────────

    local CORE_SIZE TRACKS_SIZE CORE_CHUNKS TRACKS_CHUNKS
    CORE_SIZE="$(head -1 "${CORE_PATH}.manifest")"
    TRACKS_SIZE="$(head -1 "${TRACKS_PATH}.manifest")"
    # Subtract 1 for the size line itself
    CORE_CHUNKS="$(( $(wc -l < "${CORE_PATH}.manifest") - 1 ))"
    TRACKS_CHUNKS="$(( $(wc -l < "${TRACKS_PATH}.manifest") - 1 ))"

    echo "  -> Tier '$tier' complete:"
    printf "       core:   %s MiB  (%d chunks)\n" \
        "$(awk "BEGIN{printf \"%.1f\", $CORE_SIZE/1048576}")" "$CORE_CHUNKS"
    printf "       tracks: %s MiB  (%d chunks)\n" \
        "$(awk "BEGIN{printf \"%.1f\", $TRACKS_SIZE/1048576}")" "$TRACKS_CHUNKS"

    rm -rf "$WORK_DIR"
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo "=== STK Emscripten asset generator ==="
echo "    assets:  $ASSETS_DIR"
echo "    output:  $OUTPUT_DIR"
echo "    tiers:   $TIERS"

for TIER in $TIERS; do
    eval "SZ=\$TIER_SIZE_${TIER}"
    build_tier "$TIER" "$SZ"
done

echo ""
echo "=== All tiers complete. Output: $OUTPUT_DIR ==="
