#!/bin/bash
set -e

# ── Build C/C++ dependencies with Emscripten for WebAssembly ──
#
# Compiles ogg, vorbis, opus, opusfile, openssl, zlib, curl,
# libjpeg-turbo, libpng, freetype, and harfbuzz as static WASM libraries.
#
# Requires EMSDK environment variable pointing to your Emscripten SDK.

DIRNAME=$(cd "$(dirname "$0")" && pwd)
DEPS_DIR="$DIRNAME/deps"
PREFIX="$DEPS_DIR/install"
INCLUDE="$PREFIX/include"
LIB="$PREFIX/lib"
SRC_DIR="$DEPS_DIR/src"
STAMP_DIR="$DEPS_DIR/stamps"

CORE_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ── Help ────────────────────────────────────────────
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: make_deps.sh [clean|--help]"
    echo ""
    echo "Build Emscripten/WASM dependencies for SuperTuxKart."
    echo ""
    echo "Environment variables:"
    echo "  EMSDK    Path to Emscripten SDK (required)"
    echo ""
    echo "Commands:"
    echo "  clean    Remove deps directory and all built artifacts"
    echo "  --help   Show this help message"
    exit 0
fi

# ── Clean ───────────────────────────────────────────
if [ "$1" = "clean" ]; then
    echo "Removing $DEPS_DIR"
    rm -rf "$DEPS_DIR"
    exit 0
fi

# ── Validate EMSDK ──────────────────────────────────
if [ -z "$EMSDK" ]; then
    echo "Error: EMSDK environment variable is not set."
    echo "Please set it to the path of your Emscripten SDK installation."
    echo "  export EMSDK=/path/to/emsdk"
    exit 1
fi

if [ ! -f "$EMSDK/emsdk_env.sh" ]; then
    echo "Error: $EMSDK/emsdk_env.sh not found. Is EMSDK set correctly?"
    exit 1
fi

# Source Emscripten environment
source "$EMSDK/emsdk_env.sh"

# ── Setup directories ───────────────────────────────
mkdir -p "$PREFIX" "$SRC_DIR" "$STAMP_DIR" "$INCLUDE" "$LIB"

export PKG_CONFIG_PATH="$LIB/pkgconfig"
export CFLAGS="-fwasm-exceptions -sSUPPORT_LONGJMP=wasm -pthread"
export CPPFLAGS="-fwasm-exceptions -sSUPPORT_LONGJMP=wasm -pthread"
export LDFLAGS="-fwasm-exceptions -sSUPPORT_LONGJMP=wasm -pthread"

# For cmake 4.0 until stk dependencies are updated
export CMAKE_POLICY_VERSION_MINIMUM=3.5

clone_repo() {
    local url="$1"
    local tag="$2"
    local path="$3"
    if [ ! -d "$path" ]; then
        git clone "$url" -b "$tag" --depth=1 "$path"
    fi
}

# ── ogg ─────────────────────────────────────────────
build_ogg() {
    echo "Building ogg..."
    local src="$SRC_DIR/ogg"
    clone_repo "https://github.com/xiph/ogg" v1.3.5 "$src"
    cd "$src"
    [ -f configure ] || ./autogen.sh
    emconfigure ./configure --host=none-linux --prefix="$PREFIX" --disable-shared
    emmake make -j"$CORE_COUNT"
    make install
}

# ── vorbis ──────────────────────────────────────────
build_vorbis() {
    echo "Building vorbis..."
    local src="$SRC_DIR/vorbis"
    clone_repo "https://github.com/xiph/vorbis" v1.3.7 "$src"
    cd "$src"
    [ -f configure ] || ./autogen.sh
    emconfigure ./configure --host=none-linux --prefix="$PREFIX" --with-ogg="$PREFIX" --disable-shared
    emmake make -j"$CORE_COUNT"
    make install
}

# ── opus ────────────────────────────────────────────
build_opus() {
    echo "Building opus..."
    local src="$SRC_DIR/opus"
    clone_repo "https://github.com/xiph/opus" v1.5.2 "$src"
    cd "$src"
    mkdir -p build && cd build
    emcmake cmake -G"Unix Makefiles" .. -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DOPUS_STACK_PROTECTOR=OFF
    emmake make -j"$CORE_COUNT"
    make install
}

# ── opusfile ────────────────────────────────────────
build_opusfile() {
    echo "Building opusfile..."
    local src="$SRC_DIR/opusfile"
    clone_repo "https://github.com/xiph/opusfile" v0.12 "$src"
    cd "$src"
    [ -f configure ] || ./autogen.sh
    emconfigure ./configure --host=none-linux --prefix="$PREFIX" --disable-shared \
        --disable-http \
        DEPS_CFLAGS="-I$INCLUDE -I$INCLUDE/opus" DEPS_LIBS="-L$LIB -logg -lopus"
    emmake make -j"$CORE_COUNT"
    make install
}

# ── openssl ─────────────────────────────────────────
build_openssl() {
    echo "Building openssl..."
    local src="$SRC_DIR/openssl"
    clone_repo "https://github.com/openssl/openssl" openssl-3.3.0 "$src"
    cd "$src"
    emconfigure ./Configure linux-x32 -no-asm -static -no-afalgeng -no-dso \
        -DOPENSSL_SYS_NETWARE -DSIG_DFL=0 -DSIG_IGN=0 -DHAVE_FORK=0 \
        -DOPENSSL_NO_AFALGENG=1 -DOPENSSL_NO_SPEED=1 -DOPENSSL_NO_DYNAMIC_ENGINE -DDLOPEN_FLAG=0
    sed -i.bak 's|^CROSS_COMPILE.*$|CROSS_COMPILE=|g' Makefile
    emmake make -j"$CORE_COUNT" build_generated libssl.a libcrypto.a
    mkdir -p "$INCLUDE/openssl"
    cp -r include/openssl/* "$INCLUDE/openssl/"
    cp libcrypto.a libssl.a "$LIB/"
}

# ── zlib ────────────────────────────────────────────
build_zlib() {
    echo "Building zlib..."
    local src="$SRC_DIR/zlib"
    clone_repo "https://github.com/madler/zlib" v1.3.1 "$src"
    cd "$src"
    emconfigure ./configure --prefix="$PREFIX" --static
    emmake make -j"$CORE_COUNT"
    make install
}

# ── curl ────────────────────────────────────────────
build_curl() {
    echo "Building curl..."
    local src="$SRC_DIR/curl"
    clone_repo "https://github.com/curl/curl" curl-8_8_0 "$src"
    cd "$src"
    autoreconf -fi
    emconfigure ./configure --host none-linux --prefix="$PREFIX" \
        --with-ssl="$PREFIX" --with-zlib="$PREFIX" \
        --disable-shared --disable-threaded-resolver \
        --without-libpsl --disable-netrc --disable-ipv6 \
        --disable-tftp --disable-ntlm-wb
    emmake make -j"$CORE_COUNT"
    make install
}

# ── libjpeg-turbo ───────────────────────────────────
build_jpeg() {
    echo "Building libjpeg-turbo..."
    local src="$SRC_DIR/jpeg"
    clone_repo "https://github.com/libjpeg-turbo/libjpeg-turbo" 3.0.3 "$src"
    cd "$src"
    mkdir -p build && cd build
    emcmake cmake -G"Unix Makefiles" -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX" \
        -DWITH_SIMD=0 -DENABLE_SHARED=0 ..
    emmake make -j"$CORE_COUNT"
    make install
}

# ── libpng ──────────────────────────────────────────
build_png() {
    echo "Building libpng..."
    local src="$SRC_DIR/png"
    clone_repo "https://github.com/pnggroup/libpng" v1.6.43 "$src"
    cd "$src"
    emconfigure ./configure --host none-linux --prefix="$PREFIX" --disable-shared \
        CPPFLAGS="$CPPFLAGS -I$INCLUDE" LDFLAGS="$LDFLAGS -L$LIB"
    emmake make -j"$CORE_COUNT"
    make install
}

# ── freetype ────────────────────────────────────────
build_freetype() {
    local with_harfbuzz="$1"
    local src="$SRC_DIR/freetype"
    echo "Building freetype (harfbuzz=$with_harfbuzz)..."
    clone_repo "https://github.com/freetype/freetype" VER-2-13-2 "$src"
    cd "$src"
    rm -rf build && mkdir -p build && cd build

    if [ "$with_harfbuzz" != "true" ]; then
        emcmake cmake .. -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX" \
            -DZLIB_LIBRARY="$LIB/libz.a" -DZLIB_INCLUDE_DIR="$INCLUDE" \
            -DPNG_LIBRARY="$LIB/libpng.a" -DPNG_PNG_INCLUDE_DIR="$INCLUDE"
    else
        emcmake cmake .. -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX" \
            -DZLIB_LIBRARY="$LIB/libz.a" -DZLIB_INCLUDE_DIR="$INCLUDE" \
            -DPNG_LIBRARY="$LIB/libpng.a" -DPNG_PNG_INCLUDE_DIR="$INCLUDE" \
            -DHarfBuzz_LIBRARY="$LIB/libharfbuzz.a" -DHarfBuzz_INCLUDE_DIR="$INCLUDE/harfbuzz/" \
            -DFT_REQUIRE_HARFBUZZ=TRUE
    fi
    emmake make -j"$CORE_COUNT"
    make install
}

# ── harfbuzz ────────────────────────────────────────
build_harfbuzz() {
    echo "Building harfbuzz..."
    local src="$SRC_DIR/harfbuzz"
    clone_repo "https://github.com/harfbuzz/harfbuzz" 8.5.0 "$src"
    cd "$src"
    NOCONFIGURE=1 ./autogen.sh
    emconfigure ./configure --host=none-linux --prefix="$PREFIX" --disable-shared \
        PKG_CONFIG_PATH="$LIB/pkgconfig" \
        FREETYPE_CFLAGS="-I$INCLUDE/freetype2 -I$INCLUDE" \
        FREETYPE_LIBS="-L$LIB -lfreetype -lpng16 -lz"
    emmake make -j"$CORE_COUNT"
    make install
}

# ── Build all dependencies ──────────────────────────
echo "=== Building Emscripten dependencies ==="
echo "PREFIX: $PREFIX"
echo "Using $CORE_COUNT parallel jobs"
echo ""

if [ ! -f "$STAMP_DIR/ogg.stamp" ]; then
    build_ogg
    touch "$STAMP_DIR/ogg.stamp"
else
    echo "Skipping ogg (already built)"
fi

if [ ! -f "$STAMP_DIR/vorbis.stamp" ]; then
    build_vorbis
    touch "$STAMP_DIR/vorbis.stamp"
else
    echo "Skipping vorbis (already built)"
fi

if [ ! -f "$STAMP_DIR/opus.stamp" ]; then
    build_opus
    touch "$STAMP_DIR/opus.stamp"
else
    echo "Skipping opus (already built)"
fi

if [ ! -f "$STAMP_DIR/opusfile.stamp" ]; then
    build_opusfile
    touch "$STAMP_DIR/opusfile.stamp"
else
    echo "Skipping opusfile (already built)"
fi

if [ ! -f "$STAMP_DIR/openssl.stamp" ]; then
    build_openssl
    touch "$STAMP_DIR/openssl.stamp"
else
    echo "Skipping openssl (already built)"
fi

if [ ! -f "$STAMP_DIR/zlib.stamp" ]; then
    build_zlib
    touch "$STAMP_DIR/zlib.stamp"
else
    echo "Skipping zlib (already built)"
fi

if [ ! -f "$STAMP_DIR/curl.stamp" ]; then
    build_curl
    touch "$STAMP_DIR/curl.stamp"
else
    echo "Skipping curl (already built)"
fi

if [ ! -f "$STAMP_DIR/jpeg.stamp" ]; then
    build_jpeg
    touch "$STAMP_DIR/jpeg.stamp"
else
    echo "Skipping libjpeg-turbo (already built)"
fi

if [ ! -f "$STAMP_DIR/png.stamp" ]; then
    build_png
    touch "$STAMP_DIR/png.stamp"
else
    echo "Skipping libpng (already built)"
fi

if [ ! -f "$STAMP_DIR/freetype_bootstrap.stamp" ]; then
    build_freetype false
    touch "$STAMP_DIR/freetype_bootstrap.stamp"
else
    echo "Skipping freetype bootstrap (already built)"
fi

if [ ! -f "$STAMP_DIR/harfbuzz.stamp" ]; then
    build_harfbuzz
    touch "$STAMP_DIR/harfbuzz.stamp"
else
    echo "Skipping harfbuzz (already built)"
fi

if [ ! -f "$STAMP_DIR/freetype.stamp" ]; then
    build_freetype true
    touch "$STAMP_DIR/freetype.stamp"
else
    echo "Skipping freetype with harfbuzz (already built)"
fi

echo ""
echo "=== Dependencies built successfully ==="
echo "  Headers: $INCLUDE"
echo "  Libs:    $LIB"
