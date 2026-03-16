#!/bin/bash
#
# make.sh — Build SuperTuxKart to WebAssembly with Emscripten
#
# Usage:
#   ./emscripten/make.sh [--clean] [--debug] [--help]
#
# Environment variables:
#   EMSDK          Path to your emsdk installation (required)
#   BUILD_TYPE     Release (default) or Debug
#   JOBS           Parallel jobs (default: nproc)
#   MEMORY_SIZE    Initial WASM memory in bytes (default: 536870912 = 512 MB)

set -e

DIRNAME="$(cd "$(dirname "$0")" && pwd)"
STK_ROOT="$(cd "$DIRNAME/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DO_CLEAN=0
DO_DEBUG=0

for arg in "$@"; do
    case "$arg" in
        --clean)  DO_CLEAN=1 ;;
        --debug)  DO_DEBUG=1 ;;
        --help)
            echo "Usage: $(basename "$0") [--clean] [--debug] [--help]"
            echo ""
            echo "Options:"
            echo "  --clean   Wipe the build directory and exit"
            echo "  --debug   Debug build: -O0, skips wasm-opt"
            echo "  --help    Show this message"
            echo ""
            echo "Environment variables:"
            echo "  EMSDK         Path to emsdk installation (required)"
            echo "  BUILD_TYPE    Release (default) or Debug"
            echo "  JOBS          Parallel jobs (default: nproc)"
            echo "  MEMORY_SIZE   Initial WASM memory in bytes (default: 536870912)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1
            ;;
    esac
done

# --debug flag overrides BUILD_TYPE
if [ "$DO_DEBUG" = "1" ]; then
    BUILD_TYPE="Debug"
fi
BUILD_TYPE="${BUILD_TYPE:-Release}"

# Normalise to canonical case
case "$BUILD_TYPE" in
    debug|Debug)   BUILD_TYPE="Debug" ;;
    release|Release) BUILD_TYPE="Release" ;;
    *)
        echo "Error: Unsupported BUILD_TYPE '$BUILD_TYPE'. Use Release or Debug."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BUILD_DIR="$DIRNAME/build"
OUTPUT_DIR="$DIRNAME/output"
DEPS_INSTALL="$STK_ROOT/deps/install"

# ---------------------------------------------------------------------------
# --clean
# ---------------------------------------------------------------------------
if [ "$DO_CLEAN" = "1" ]; then
    echo "Cleaning build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    echo "Done."
    exit 0
fi

# ---------------------------------------------------------------------------
# Portable job count
# ---------------------------------------------------------------------------
if [ -z "$JOBS" ]; then
    if command -v nproc >/dev/null 2>&1; then
        JOBS="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
    else
        JOBS=4
    fi
fi

MEMORY_SIZE="${MEMORY_SIZE:-536870912}"

echo "=== SuperTuxKart Emscripten Build ==="
echo "  Build type:  $BUILD_TYPE"
echo "  Jobs:        $JOBS"
echo "  Memory:      $MEMORY_SIZE bytes"
echo "  Build dir:   $BUILD_DIR"
echo "  Output dir:  $OUTPUT_DIR"
echo ""

# ---------------------------------------------------------------------------
# 1. Source emsdk
# ---------------------------------------------------------------------------
echo "[1/5] Setting up Emscripten..."

if [ -z "$EMSDK" ]; then
    echo "Error: EMSDK environment variable is not set."
    echo "Set it to the path of your emsdk installation, e.g.:"
    echo "  export EMSDK=\$HOME/emsdk"
    exit 1
fi

if [ ! -f "$EMSDK/emsdk_env.sh" ]; then
    echo "Error: emsdk_env.sh not found at $EMSDK/emsdk_env.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "$EMSDK/emsdk_env.sh"

echo "  Emscripten: $(emcc --version | head -1)"

# ---------------------------------------------------------------------------
# 2. Ensure SDL2 threaded port
# ---------------------------------------------------------------------------
echo "[2/5] Ensuring SDL2 threaded port..."
embuilder build sdl2-mt

# ---------------------------------------------------------------------------
# 3. CMake configure
# ---------------------------------------------------------------------------
echo "[3/5] Configuring with CMake ($BUILD_TYPE)..."
mkdir -p "$BUILD_DIR"

if [ "$BUILD_TYPE" = "Debug" ]; then
    OPT_CFLAGS="-O0"
    OPT_LDFLAGS="-O0"
    EXTRA_CMAKE_FLAGS=""
else
    OPT_CFLAGS="-Oz -flto"
    OPT_LDFLAGS="-Oz -flto"
    EXTRA_CMAKE_FLAGS=""
fi

cd "$BUILD_DIR"

emcmake cmake "$STK_ROOT" \
    -DCMAKE_FIND_ROOT_PATH="$DEPS_INSTALL" \
    -DNO_SHADERC=on \
    -DBUILD_RECORDER=0 \
    -DHAVE_OPUS=ON \
    -DUSE_CRYPTO_OPENSSL=ON \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_C_FLAGS="$OPT_CFLAGS -pthread" \
    -DCMAKE_CXX_FLAGS="$OPT_CFLAGS -pthread" \
    -DCMAKE_EXE_LINKER_FLAGS="$OPT_LDFLAGS -pthread \
        -sWASM=1 \
        -sALLOW_MEMORY_GROWTH=1 \
        -sINITIAL_MEMORY=${MEMORY_SIZE}" \
    $EXTRA_CMAKE_FLAGS

# ---------------------------------------------------------------------------
# 4. Compile
# ---------------------------------------------------------------------------
echo "[4/5] Compiling with $JOBS parallel jobs..."
emmake make -j"$JOBS"

# ---------------------------------------------------------------------------
# 5. Post-build: wasm-opt + copy output
# ---------------------------------------------------------------------------
echo "[5/5] Post-build: copying output..."

mkdir -p "$OUTPUT_DIR"

WASM_FILE="$BUILD_DIR/bin/supertuxkart.wasm"
JS_FILE="$BUILD_DIR/bin/supertuxkart.js"

if [ ! -f "$WASM_FILE" ]; then
    echo "Error: Expected output not found: $WASM_FILE"
    exit 1
fi

if [ "$BUILD_TYPE" = "Release" ]; then
    if command -v wasm-opt >/dev/null 2>&1; then
        echo "  Running wasm-opt -Oz..."
        wasm-opt -Oz "$WASM_FILE" -o "$WASM_FILE"
    else
        echo "  Warning: wasm-opt not found, skipping size optimization."
    fi
else
    echo "  Debug build: skipping wasm-opt."
fi

cp "$BUILD_DIR"/bin/supertuxkart.wasm "$OUTPUT_DIR/"
cp "$BUILD_DIR"/bin/supertuxkart.js   "$OUTPUT_DIR/"

# Copy any additional generated data files (e.g. .data, worker JS)
for f in "$BUILD_DIR"/bin/supertuxkart.*; do
    case "$f" in
        *.wasm|*.js) ;;  # already copied above
        *) cp "$f" "$OUTPUT_DIR/" 2>/dev/null || true ;;
    esac
done

echo ""
echo "=== BUILD COMPLETE ==="
echo "  Output: $OUTPUT_DIR"
echo ""
