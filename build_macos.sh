#!/usr/bin/env bash
set -euo pipefail

# Build ungoogled-chromium for macOS (Apple Silicon) and install to /Applications
#
# Usage:
#   ./build_macos.sh          # full: setup + install
#   ./build_macos.sh setup    # download, patch, configure (no compile)
#   ./build_macos.sh install  # compile + sign + install (requires setup)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_REPO="$SCRIPT_DIR/macos"
PARALLELISM=${JOBS:-$(sysctl -n hw.logicalcpu)}
ARCHIVE_DIR="${CHROMIUM_ARCHIVE:-$HOME/.local/share/ungoogled-chromium/archives}"
KEYCHAIN_API_KEY_SERVICE="ungoogled-chromium-google-api-key"
MODE="${1:-full}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}→ $*${NC}"; }
log_warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
log_error() { echo -e "${RED}✗ $*${NC}" >&2; }
log_done() { echo -e "${GREEN}✓ $*${NC}"; }
_elapsed() { printf '%dh%02dm%02ds' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

_BUILD_LOG=$(mktemp)
trap 'rm -f "$_BUILD_LOG"' EXIT

run_quiet() {
    local label="$1"
    shift
    log_info "$label"
    if "$@" > "$_BUILD_LOG" 2>&1; then
        return 0
    else
        local rc=$?
        log_error "$label failed. Log:"
        cat "$_BUILD_LOG" >&2
        exit $rc
    fi
}

_check_deps() {
    if ! xcode-select -p &>/dev/null; then
        log_error "Xcode CLI tools not installed. Run: xcode-select --install"
        exit 1
    fi
    local missing=()
    command -v greadlink >/dev/null || missing+=(coreutils)
    command -v ninja >/dev/null || missing+=(ninja)
    command -v python3 >/dev/null || missing+=(python3)
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[*]}. Run: brew install ${missing[*]}"
        exit 1
    fi
    if ! command -v sccache >/dev/null && ! command -v ccache >/dev/null; then
        log_warn "No compilation cache. Recommended: brew install sccache"
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
            echo "  Archiving old version ($old_ver)"
            mv /Applications/Chromium.app "$ARCHIVE_DIR/$archive_name"
        else
            rm -rf /Applications/Chromium.app
        fi
    fi
    cp -R "$src_app" /Applications/Chromium.app
}

# args.gn is derived only from the flags files, so redoing it never needs the source tree
_configure() {
    log_info "Configure (GN, arm64)"
    mkdir -p "$_SRC/out/Default"
    cat "$_MAIN/flags.gn" "$_ROOT/flags.macos.gn" > "$_SRC/out/Default/args.gn"
    cat >> "$_SRC/out/Default/args.gn" <<'GN'
target_cpu = "arm64"
symbol_level=0
use_thin_lto=true
thin_lto_enable_optimizations=true
is_component_build=false
use_lld=true
enable_dsyms=false
GN

    if command -v sccache >/dev/null; then
        echo 'cc_wrapper="sccache"' >> "$_SRC/out/Default/args.gn"
        echo "  Using sccache"
    elif command -v ccache >/dev/null; then
        echo 'cc_wrapper="ccache"' >> "$_SRC/out/Default/args.gn"
        echo "  Using ccache"
    fi

    # bake a personal api key into the build; env first, then keychain, never the repo
    _api_key="${GOOGLE_API_KEY:-${GOOGLE_TRANSLATION_KEY:-}}"
    _api_key_src="environment"
    if [[ -z "$_api_key" ]]; then
        _api_key="$(security find-generic-password -w -s "$KEYCHAIN_API_KEY_SERVICE" 2>/dev/null || true)"
        _api_key_src="keychain"
    fi
    if [[ -n "$_api_key" ]]; then
        sed -i '' "s|^google_api_key=.*|google_api_key=\"$_api_key\"|" "$_SRC/out/Default/args.gn"
        # verify the substitution landed instead of trusting sed
        if ! grep -qE '^google_api_key="[^"]+"$' "$_SRC/out/Default/args.gn"; then
            log_error "google_api_key was not written into args.gn"
            exit 1
        fi
        log_done "Google API key: ${#_api_key} chars from $_api_key_src"
    elif [[ -n "${SKIP_API_KEY:-}" ]]; then
        log_warn "SKIP_API_KEY set; building without translation support"
    else
        log_error "No Google API key found; translation would be missing from this build"
        log_error "  export GOOGLE_API_KEY=... or GOOGLE_TRANSLATION_KEY=..."
        log_error "  store once:   security add-generic-password -a \"\$USER\" -s $KEYCHAIN_API_KEY_SERVICE -w"
        log_error "  build anyway: SKIP_API_KEY=1 just setup"
        exit 1
    fi
    unset _api_key _api_key_src
}

# identifies a finished tree: the chromium version plus every patch applied to it
_tree_signature() {
    {
        cat "$_MAIN/chromium_version.txt"
        find "$_MAIN/patches" "$_ROOT/patches" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum
    } | shasum | cut -d' ' -f1
}

# identifies the gn configuration; changing it only costs a reconfigure, not a re-download
_config_signature() {
    cat "$_MAIN/flags.gn" "$_ROOT/flags.macos.gn" | shasum | cut -d' ' -f1
}

_setup() {
    _tree_sig=$(_tree_signature)
    _cfg_sig=$(_config_signature)

    # setup is idempotent: the stamp records which tree and which gn flags produced out/Default
    if [[ -f "$_STAMP" && -d "$_SRC/out/Default" ]] && [[ "$(sed -n 1p "$_STAMP")" == "$_tree_sig" ]]; then
        if [[ "$(sed -n 2p "$_STAMP")" == "$_cfg_sig" ]]; then
            log_done "Source tree already set up for $(cat "$_MAIN/chromium_version.txt")"
            return
        fi
        # source is unchanged and only the gn flags moved, so skip straight to reconfiguring
        log_info "Build flags changed; reconfiguring without re-downloading"
        _configure
        cd "$_SRC"
        run_quiet "GN gen" ./out/Default/gn gen out/Default --fail-on-unused-args
        printf '%s\n%s\n' "$_tree_sig" "$_cfg_sig" > "$_STAMP"
        return
    fi

    # any other state is stale or half-finished; patches and domain substitution cannot re-apply
    if [[ -e "$_SRC" || -e "$_ROOT/build/domsubcache.tar.gz" ]]; then
        log_warn "Discarding unusable source tree at $_SRC"
        rm -rf "$_SRC" "$_ROOT/build/domsubcache.tar.gz"
    fi

    mkdir -p "$_DOWNLOAD_CACHE"

    run_quiet "Validate config" \
        python3 "$_MAIN/devutils/validate_config.py"

    log_info "Download source"
    python3 "$_MAIN/utils/downloads.py" retrieve -i "$_MAIN/downloads.ini" -c "$_DOWNLOAD_CACHE"
    run_quiet "Unpack source" \
        python3 "$_MAIN/utils/downloads.py" unpack -i "$_MAIN/downloads.ini" -c "$_DOWNLOAD_CACHE" "$_SRC"

    run_quiet "Prune binaries" \
        python3 "$_MAIN/utils/prune_binaries.py" "$_SRC" "$_MAIN/pruning.list"

    run_quiet "Apply patches" \
        python3 "$_MAIN/utils/patches.py" apply "$_SRC" "$_MAIN/patches" "$_ROOT/patches"

    run_quiet "Domain substitution" \
        python3 "$_MAIN/utils/domain_substitution.py" apply -r "$_MAIN/domain_regex.list" -f "$_MAIN/domain_substitution.list" -c "$_ROOT/build/domsubcache.tar.gz" "$_SRC"

    _configure

    log_info "Download arm64 toolchain"
    rm -rf "$_SRC/third_party/llvm-build/Release+Asserts/" "$_SRC/third_party/rust-toolchain/" "$_SRC/third_party/node/mac_arm64/"
    mkdir -p "$_SRC/third_party/llvm-build/Release+Asserts"
    mkdir -p "$_SRC/third_party/rust-toolchain/bin"
    mkdir -p "$_SRC/third_party/node/mac_arm64/node-darwin-arm64/"

    python3 "$_MAIN/utils/downloads.py" retrieve -i "$_ROOT/downloads-arm64.ini" -c "$_DOWNLOAD_CACHE"
    run_quiet "Unpack arm64 toolchain" \
        python3 "$_MAIN/utils/downloads.py" unpack -i "$_ROOT/downloads-arm64.ini" -c "$_DOWNLOAD_CACHE" "$_SRC"

    python3 "$_MAIN/utils/downloads.py" retrieve -i "$_ROOT/downloads-arm64-rustlib.ini" -c "$_DOWNLOAD_CACHE"
    rm -rf "$_SRC/third_party/rust-toolchain/rustc/lib/rustlib/aarch64-apple-darwin"
    run_quiet "Unpack rustlib" \
        python3 "$_MAIN/utils/downloads.py" unpack -i "$_ROOT/downloads-arm64-rustlib.ini" -c "$_DOWNLOAD_CACHE" "$_SRC"

    log_info "Setup toolchain symlinks"
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

    # the lite tarball ships no pgo profile, so fetch the one this version pins
    _pgo_txt="$_SRC/chrome/build/mac-arm.pgo.txt"
    if [[ -f "$_pgo_txt" ]]; then
        _pgo_name="$(tr -d '[:space:]' < "$_pgo_txt")"
        mkdir -p "$_SRC/chrome/build/pgo_profiles"
        if [[ ! -s "$_SRC/chrome/build/pgo_profiles/$_pgo_name" ]]; then
            run_quiet "Download PGO profile" \
                curl -fL --retry 3 -o "$_SRC/chrome/build/pgo_profiles/$_pgo_name" \
                "https://storage.googleapis.com/chromium-optimization-profiles/pgo_profiles/$_pgo_name"
        fi
    fi

    # chromium 152 generates tint enums with go, fetched via cipd and absent from tarballs
    _dawn_go="$_SRC/third_party/dawn/tools/golang/mac-arm64"
    if [[ ! -x "$_dawn_go/bin/go" ]]; then
        if ! command -v go >/dev/null; then
            log_error "go is required to generate dawn/tint sources; brew install go"
            exit 1
        fi
        mkdir -p "$(dirname "$_dawn_go")"
        ln -sfn "$(go env GOROOT)" "$_dawn_go"
        log_done "Dawn go toolchain: $(go env GOROOT)"
    fi

    run_quiet "Bootstrap GN" \
        ./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
    run_quiet "Build bindgen" \
        ./tools/rust/build_bindgen.py --skip-test
    run_quiet "GN gen" \
        ./out/Default/gn gen out/Default --fail-on-unused-args

    # written last so an interrupted setup is never mistaken for a finished one
    printf '%s\n%s\n' "$_tree_sig" "$_cfg_sig" > "$_STAMP"

    log_info "Cleanup download cache"
    rm -rf "$_DOWNLOAD_CACHE"
}

_install() {
    if [[ ! -d "$_SRC/out/Default" ]]; then
        log_error "No setup found. Run: just setup"
        exit 1
    fi
    cd "$_SRC"
    run_quiet "GN gen" ./out/Default/gn gen out/Default --fail-on-unused-args

    log_info "Build (j=$PARALLELISM)"
    _t_build=$SECONDS
    ninja -j"$PARALLELISM" -C out/Default chrome
    log_done "Compile+link took $(_elapsed $((SECONDS - _t_build)))"

    log_info "Sign → Install"
    xattr -cs out/Default/Chromium.app
    codesign --force --deep --sign "Chromium Dev" out/Default/Chromium.app
    _install_chromium out/Default/Chromium.app
}

# --- main ---

_check_deps

if [[ ! -f "$MACOS_REPO/flags.macos.gn" ]]; then
    log_info "Initializing macos submodule"
    git -C "$SCRIPT_DIR" submodule update --init macos
fi

cd "$MACOS_REPO"
if [[ -d "$MACOS_REPO/ungoogled-chromium" && ! -L "$MACOS_REPO/ungoogled-chromium" ]]; then
    rm -rf "$MACOS_REPO/ungoogled-chromium"
fi
ln -sfn "$SCRIPT_DIR" "$MACOS_REPO/ungoogled-chromium"

_ROOT="$MACOS_REPO"
_MAIN="$_ROOT/ungoogled-chromium"
_DOWNLOAD_CACHE="$_ROOT/build/download_cache"
_SRC="$_ROOT/build/src"
_STAMP="$_ROOT/build/.setup-complete"

case "$MODE" in
    setup)
        _setup
        echo ""
        log_done "Setup complete in $(_elapsed $SECONDS). Run: just install"
        ;;
    install)
        _install
        echo ""
        log_done "Chromium $(cat "$_MAIN/chromium_version.txt") → /Applications in $(_elapsed $SECONDS)"
        ;;
    full)
        _setup
        _install
        echo ""
        log_done "Chromium $(cat "$_MAIN/chromium_version.txt") → /Applications in $(_elapsed $SECONDS)"
        ;;
    *)
        echo "Usage: $0 [setup|install|full]"
        exit 1
        ;;
esac
