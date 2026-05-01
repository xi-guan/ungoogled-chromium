#!/usr/bin/env bash
set -euo pipefail

# Build ungoogled-chromium for macOS (Apple Silicon) and install to /Applications
# Requirements: Xcode CLI tools, brew install coreutils ninja
#
# Usage:
#   ./build_macos.sh          # full build (download, patch, compile)
#   ./build_macos.sh rebuild  # incremental: skip download/patch, just ninja

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_REPO="$SCRIPT_DIR/macos"
PARALLELISM=${JOBS:-$(sysctl -n hw.logicalcpu)}
ARCHIVE_DIR="${CHROMIUM_ARCHIVE:-$HOME/.local/share/ungoogled-chromium/archives}"
MODE="${1:-full}"

# --- preflight checks ---
_check_deps() {
    if ! xcode-select -p &>/dev/null; then
        echo "Xcode CLI tools not installed."
        echo "Run: xcode-select --install"
        exit 1
    fi
    local missing=()
    command -v greadlink >/dev/null || missing+=(coreutils)
    command -v ninja >/dev/null || missing+=(ninja)
    command -v python3 >/dev/null || missing+=(python3)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}"
        echo "Run: brew install ${missing[*]}"
        exit 1
    fi
    if ! command -v sccache >/dev/null && ! command -v ccache >/dev/null; then
        echo "Note: install sccache for faster rebuilds: brew install sccache"
    fi
}

_install_chromium() {
    local src_app="$1"
    if [[ -d "/Applications/Chromium.app" ]]; then
        local old_ver
        old_ver=$(defaults read /Applications/Chromium.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")
        local archive_name="Chromium-${old_ver}.app"
        if [[ ! -d "$ARCHIVE_DIR/$archive_name" ]]; then
            mkdir -p "$ARCHIVE_DIR"
            echo "==> Archiving old version ($old_ver) to $ARCHIVE_DIR/$archive_name"
            mv /Applications/Chromium.app "$ARCHIVE_DIR/$archive_name"
        else
            rm -rf /Applications/Chromium.app
        fi
    fi
    cp -R "$src_app" /Applications/Chromium.app
}

_check_deps

# --- ensure submodule is initialized ---
if [[ ! -f "$MACOS_REPO/flags.macos.gn" ]]; then
    echo "==> Initializing macos submodule..."
    git -C "$SCRIPT_DIR" submodule update --init macos
fi

cd "$MACOS_REPO"

# point macos repo's ungoogled-chromium reference back to parent
ln -sfn "$SCRIPT_DIR" "$MACOS_REPO/ungoogled-chromium"

_ROOT="$MACOS_REPO"
_MAIN="$_ROOT/ungoogled-chromium"
_DOWNLOAD_CACHE="$_ROOT/build/download_cache"
_SRC="$_ROOT/build/src"

if [[ "$MODE" == "rebuild" ]]; then
    if [[ ! -d "$_SRC/out/Default" ]]; then
        echo "Error: no previous build found, run full build first"
        exit 1
    fi
    echo "==> Incremental rebuild (skipping download/patch/domsub)"
    cd "$_SRC"
    ./out/Default/gn gen out/Default --fail-on-unused-args
    echo "==> Building (j=$PARALLELISM)..."
    ninja -j"$PARALLELISM" -C out/Default chrome
    echo "==> Signing..."
    xattr -cs out/Default/Chromium.app
    codesign --force --deep --sign "Chromium Dev" out/Default/Chromium.app
    echo "==> Installing to /Applications..."
    _install_chromium out/Default/Chromium.app
    echo ""
    echo "Done! Chromium installed to /Applications/Chromium.app"
    echo "Version: $(cat "$_MAIN/chromium_version.txt")"
    exit 0
fi

mkdir -p "$_DOWNLOAD_CACHE"

# --- retrieve and unpack source ---
echo "==> Downloading Chromium source (this takes a while)..."
python3 "$_MAIN/utils/downloads.py" retrieve -i "$_MAIN/downloads.ini" -c "$_DOWNLOAD_CACHE"
python3 "$_MAIN/utils/downloads.py" unpack -i "$_MAIN/downloads.ini" -c "$_DOWNLOAD_CACHE" "$_SRC"


# --- prune, patch, domain substitution (must run BEFORE toolchain download) ---
echo "==> Pruning binaries..."
python3 "$_MAIN/utils/prune_binaries.py" "$_SRC" "$_MAIN/pruning.list"

echo "==> Applying patches..."
python3 "$_MAIN/utils/patches.py" apply "$_SRC" "$_MAIN/patches" "$_ROOT/patches"

echo "==> Domain substitution..."
python3 "$_MAIN/utils/domain_substitution.py" apply -r "$_MAIN/domain_regex.list" -f "$_MAIN/domain_substitution.list" -c "$_ROOT/build/domsubcache.tar.gz" "$_SRC"

# --- configure build ---
echo "==> Configuring build..."
mkdir -p "$_SRC/out/Default"
cat "$_MAIN/flags.gn" "$_ROOT/flags.macos.gn" > "$_SRC/out/Default/args.gn"
echo 'target_cpu = "arm64"' >> "$_SRC/out/Default/args.gn"

# performance: reduce debug info and link time
cat >> "$_SRC/out/Default/args.gn" <<'GN'
symbol_level=0
use_thin_lto=true
thin_lto_enable_optimizations=true
is_component_build=false
use_lld=true
enable_dsyms=false
GN

# use sccache if available
if command -v sccache >/dev/null; then
    echo 'cc_wrapper="sccache"' >> "$_SRC/out/Default/args.gn"
    echo "==> Using sccache for compilation cache"
elif command -v ccache >/dev/null; then
    echo 'cc_wrapper="ccache"' >> "$_SRC/out/Default/args.gn"
    echo "==> Using ccache for compilation cache"
fi

# --- arch-specific deps (arm64, after prune to avoid deletion) ---
echo "==> Downloading arm64 toolchain..."
rm -rf "$_SRC/third_party/llvm-build/Release+Asserts/" "$_SRC/third_party/rust-toolchain/" "$_SRC/third_party/node/mac_arm64/"
mkdir -p "$_SRC/third_party/llvm-build/Release+Asserts"
mkdir -p "$_SRC/third_party/rust-toolchain/bin"
mkdir -p "$_SRC/third_party/node/mac_arm64/node-darwin-arm64/"

python3 "$_MAIN/utils/downloads.py" retrieve -i "$_ROOT/downloads-arm64.ini" -c "$_DOWNLOAD_CACHE"
python3 "$_MAIN/utils/downloads.py" unpack -i "$_ROOT/downloads-arm64.ini" -c "$_DOWNLOAD_CACHE" "$_SRC"

python3 "$_MAIN/utils/downloads.py" retrieve -i "$_ROOT/downloads-arm64-rustlib.ini" -c "$_DOWNLOAD_CACHE"
rm -rf "$_SRC/third_party/rust-toolchain/rustc/lib/rustlib/aarch64-apple-darwin"
python3 "$_MAIN/utils/downloads.py" unpack -i "$_ROOT/downloads-arm64-rustlib.ini" -c "$_DOWNLOAD_CACHE" "$_SRC"

# setup rust symlinks
_RUST_DIR="$_SRC/third_party/rust-toolchain"
_RUST_BIN="$_RUST_DIR/bin"
_RUST_NAME="aarch64-apple-darwin"
mkdir -p "$_RUST_BIN" "$_RUST_DIR/lib"
ln -sf "$_RUST_DIR/rustc/bin/rustc" "$_RUST_BIN/rustc"
ln -sf "$_RUST_DIR/cargo/bin/cargo" "$_RUST_BIN/cargo"
ln -sf "$_RUST_DIR/rustfmt-preview/bin/rustfmt" "$_RUST_BIN/rustfmt"
ln -sf "$_RUST_DIR/rust-std-$_RUST_NAME/lib/rustlib/$_RUST_NAME/lib" "$_RUST_DIR/rustc/lib/rustlib/$_RUST_NAME/lib"
ln -sf "$_RUST_DIR/rustc/lib" "$_RUST_DIR/rustfmt-preview/lib"

_LLVM_BIN="$_SRC/third_party/llvm-build/Release+Asserts/bin"
ln -sf "$_LLVM_BIN/llvm-install-name-tool" "$_LLVM_BIN/install_name_tool"
ln -sf "$_LLVM_BIN/llvm-objcopy" "$_RUST_BIN/rust-objcopy"

cd "$_SRC"
export PATH="$_SRC/third_party/rust-toolchain/bin:$PATH"

# bootstrap GN
./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
./tools/rust/build_bindgen.py --skip-test

./out/Default/gn gen out/Default --fail-on-unused-args

# --- build ---
echo "==> Building (j=$PARALLELISM)..."
ninja -j"$PARALLELISM" -C out/Default chrome

# --- sign (ad-hoc) and install ---
echo "==> Signing..."
xattr -cs out/Default/Chromium.app
codesign --force --deep --sign "Chromium Dev" out/Default/Chromium.app

echo "==> Installing to /Applications..."
_install_chromium out/Default/Chromium.app

echo "==> Cleaning download cache..."
rm -rf "$_DOWNLOAD_CACHE"

echo ""
echo "Done! Chromium installed to /Applications/Chromium.app"
echo "Version: $(cat "$_MAIN/chromium_version.txt")"
