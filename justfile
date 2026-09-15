set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

macos_repo := justfile_directory() / "macos"
src := macos_repo / "build/src"
version := `cat chromium_version.txt`
archive_dir := env("CHROMIUM_ARCHIVE", home_directory() / ".local/share/ungoogled-chromium/archives")

_default:
    @just --list --unsorted --list-heading '' --list-prefix='- '

# sync fork with upstream
pull:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    log_info "syncing fork with upstream on GitHub"
    gh repo sync xi-guan/ungoogled-chromium --source ungoogled-software/ungoogled-chromium
    log_info "pulling from origin with rebase"
    git pull --rebase --autostash
    log_info "updating macos submodule"
    git submodule update --remote macos
    log_done "pull complete"

# download source, apply patches, configure toolchain
setup:
    ./build_macos.sh setup

# compile and install to /Applications
install:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -d "{{src}}/out/Default" ]]; then
        ./build_macos.sh install
    else
        ./build_macos.sh
    fi

# clean rebuild from scratch
reinstall:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf "{{macos_repo}}/build/src" "{{macos_repo}}/build/domsubcache.tar.gz" "{{macos_repo}}/build/.setup-complete"
    ./build_macos.sh

# remove Chromium from /Applications
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    if [[ ! -d "/Applications/Chromium.app" ]]; then
        log_warn "Chromium.app not found in /Applications"
        exit 0
    fi
    read -rp "Remove /Applications/Chromium.app? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    rm -rf /Applications/Chromium.app
    log_done "uninstall complete"

# validate config files (patches, GN flags, downloads.ini)
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    run_quiet "validating config" python3 devutils/validate_config.py
    log_done "config valid"

# show current version and archived versions
version:
    #!/usr/bin/env bash
    echo "Current: {{version}}"
    archives=()
    while IFS= read -r app; do
        archives+=("$(basename "$app" .app | sed 's/^Chromium-//')")
    done < <(ls -1dt "{{archive_dir}}"/Chromium-*.app 2>/dev/null)
    if [[ ${#archives[@]} -gt 0 ]]; then
        echo "Archives:"
        for ver in "${archives[@]}"; do
            echo "  - $ver"
        done
    fi

# clean disk or archives: just clean <disk|archives>
clean target:
    @just _clean-{{target}}

[private]
_clean-disk:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v fzf >/dev/null || { echo "fzf required: brew install fzf"; exit 1; }
    items=()
    if [[ -d "{{src}}/out/Default" ]]; then
        size=$(du -sh "{{src}}/out/Default" 2>/dev/null | cut -f1)
        items+=("build-output ($size) — build artifacts only, keeps patched source")
    fi
    if [[ -d "{{src}}" ]]; then
        size=$(du -sh "{{src}}" 2>/dev/null | cut -f1)
        items+=("build-source ($size) — entire source tree, next install needs setup")
    fi
    if [[ -d "{{macos_repo}}/build/download_cache" ]]; then
        size=$(du -sh "{{macos_repo}}/build/download_cache" 2>/dev/null | cut -f1)
        items+=("download-cache ($size) — cached tarballs, will re-download next setup")
    fi
    if [[ ${#items[@]} -eq 0 ]]; then
        echo "Nothing to clean."
        exit 0
    fi
    selected=$(printf '%s\n' "${items[@]}" | fzf --multi --header="Select items to clean (TAB to toggle, ENTER to confirm)")
    [[ -z "$selected" ]] && exit 0
    if echo "$selected" | grep -q "^build-source"; then
        rm -rf "{{src}}" "{{macos_repo}}/build/domsubcache.tar.gz" "{{macos_repo}}/build/.setup-complete"
        echo "✓ Removed build source"
    elif echo "$selected" | grep -q "^build-output"; then
        rm -rf "{{src}}/out/Default"
        echo "✓ Removed build output"
    fi
    if echo "$selected" | grep -q "^download-cache"; then
        rm -rf "{{macos_repo}}/build/download_cache"
        echo "✓ Removed download cache"
    fi

[private]
_clean-archives:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v fzf >/dev/null || { echo "fzf required: brew install fzf"; exit 1; }
    mapfile -t all < <(ls -1dt "{{archive_dir}}"/Chromium-*.app 2>/dev/null)
    if [[ ${#all[@]} -eq 0 ]]; then
        echo "No archives."
        exit 0
    fi
    items=()
    for app in "${all[@]}"; do
        name=$(basename "$app" .app | sed 's/^Chromium-//')
        size=$(du -sh "$app" 2>/dev/null | cut -f1)
        items+=("$name ($size)")
    done
    selected=$(printf '%s\n' "${items[@]}" | fzf --multi --header="Select archives to remove (TAB to toggle, ENTER to confirm)")
    [[ -z "$selected" ]] && exit 0
    while IFS= read -r line; do
        ver=$(echo "$line" | sed 's/ .*//')
        rm -rf "{{archive_dir}}/Chromium-${ver}.app"
        echo "✓ Removed Chromium $ver"
    done <<< "$selected"
