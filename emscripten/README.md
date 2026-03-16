# Emscripten/WebAssembly Build for SuperTuxKart

Build SuperTuxKart as a WebAssembly application that runs in modern browsers via WebGL 2.

## Prerequisites

- [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html) (3.1.x or later)
- `opus-tools` (for audio conversion)
- `zstd` (for asset compression)
- `python3` (for local dev server)

On macOS:
```bash
brew install opus-tools zstd
```

## Build Steps

### 1. Set up Emscripten SDK

```bash
export EMSDK=/path/to/emsdk
source $EMSDK/emsdk_env.sh
```

### 2. Build dependencies

```bash
cd emscripten
./make_deps.sh
```

This compiles zlib, libpng, libjpeg, freetype, harfbuzz, opus, opusfile,
openssl, curl, and other dependencies as static WASM libraries. Uses stamp
files for incremental builds — re-run safely after interruptions.

To clean and rebuild: `./make_deps.sh clean`

### 3. Build the game

```bash
./make.sh
```

Options:
- `./make.sh --debug` — debug build (no optimizations)
- `./make.sh --clean` — clean build directory first

Output goes to `emscripten/output/`.

### 4. Generate assets

```bash
./generate_assets.sh /path/to/stk-assets ./output
```

Set quality tier via environment variable:
- `ASSET_QUALITY=low` — 128px textures (~110 MiB download)
- `ASSET_QUALITY=mid` — 256px textures (~155 MiB download)
- `ASSET_QUALITY=high` — original resolution (~220 MiB download)
- `ASSET_QUALITY=all` — builds all three tiers

Assets are compressed with zstd and split into 20MB chunks for progressive
browser download.

### 5. Run locally

```bash
cd output
python3 ../web/run_server.py
```

Open `http://localhost:8080` in your browser.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMSDK` | (required) | Path to Emscripten SDK |
| `ASSET_QUALITY` | `low` | Asset quality tier |
| `BUILD_TYPE` | `Release` | `Release` or `Debug` |
| `MEMORY_SIZE` | `536870912` | Initial WASM memory (bytes, 512MB default) |
| `JOBS` | auto-detected | Parallel build jobs |

## Troubleshooting

### SharedArrayBuffer not available

SuperTuxKart uses pthreads, which require SharedArrayBuffer. This needs
specific HTTP headers:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

The included `run_server.py` sets these automatically. For other servers,
`coi-serviceworker.js` injects them client-side (used for GitHub Pages).

### Game runs slowly

- Try "Low" texture quality to reduce memory pressure
- Close other browser tabs
- Ensure hardware acceleration is enabled in browser settings

### Audio issues

All audio is encoded as Opus (24 kbps). The game requires a browser with
Opus support (all modern browsers support this).

## Architecture

```
emscripten/
├── make_deps.sh          # Compile native dependencies with emcc
├── generate_assets.sh    # Convert audio, compress textures, create archives
├── make.sh               # Build WASM binary
├── convert_to_opus.sh    # Audio conversion utility
├── deps/                 # Built dependencies (generated)
├── build/                # CMake build directory (generated)
├── output/               # Final WASM + assets (generated)
└── web/                  # Browser runtime
    ├── index.html        # HTML shell with quality selector
    ├── script.js         # Asset downloader, IDBFS, game launcher
    ├── coi-serviceworker.js  # COOP/COEP headers for SharedArrayBuffer
    ├── run_server.py     # Local dev server with correct headers
    └── config_example.json   # Example configuration
```
