set dotenv-load := false

macos_repo := justfile_directory() / "macos"
main := justfile_directory()
src := macos_repo / "build/src"
version := `cat chromium_version.txt`
jobs := `sysctl -n hw.logicalcpu`

# list available recipes
default:
    @just --list

# sync fork with upstream, rebase local changes on top
pull:
    gh repo sync xi-guan/ungoogled-chromium --source ungoogled-software/ungoogled-chromium
    git pull --rebase
    git submodule update --remote macos

# full build, install to /Applications
release:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -d "{{src}}/out/Default" ]]; then
        echo "==> Incremental rebuild..."
        ./build_macos.sh rebuild
    else
        echo "==> Full build..."
        ./build_macos.sh
    fi

# full build: download, patch, compile, install
build:
    ./build_macos.sh

# incremental rebuild: skip download/patch, just ninja + install
rebuild:
    ./build_macos.sh rebuild

# full clean build from scratch
clean-build:
    rm -rf "{{macos_repo}}/build/src" "{{macos_repo}}/build/domsubcache.tar.gz"
    ./build_macos.sh

# remove build source to reclaim disk space (loses incremental rebuild)
clean:
    rm -rf "{{macos_repo}}/build/src" "{{macos_repo}}/build/domsubcache.tar.gz"
    @echo "Cleaned build source. Next build will be full."

# show sccache stats
cache-stats:
    sccache --show-stats

# reset sccache
cache-clear:
    sccache --zero-stats

# validate config files
validate:
    ./devutils/validate_config.py

# run tests
test:
    ./devutils/run_utils_tests.sh
    ./devutils/run_devutils_tests.sh

# show current version
version:
    @echo "{{version}}"

# show build output size
size:
    @du -sh "{{src}}/out/Default/Chromium.app" 2>/dev/null || echo "no build found"

# list archived versions
archives:
    @ls -1d ~/.local/share/ungoogled-chromium/archives/Chromium-*.app 2>/dev/null | sed 's|.*/||' || echo "no archives"

# remove archived versions older than N (default: keep latest 3)
clean-archives keep="3":
    #!/usr/bin/env bash
    set -euo pipefail
    dir="${CHROMIUM_ARCHIVE:-$HOME/.local/share/ungoogled-chromium/archives}"
    mapfile -t all < <(ls -1dt "$dir"/Chromium-*.app 2>/dev/null)
    if [[ ${#all[@]} -le {{keep}} ]]; then
        echo "Only ${#all[@]} archive(s), nothing to clean (keeping {{keep}})"
        exit 0
    fi
    for app in "${all[@]:{{keep}}}"; do
        echo "Removing $(basename "$app")..."
        rm -rf "$app"
    done
    echo "Kept latest {{keep}} version(s)"
