# Operations Guide

## Prerequisites

- macOS (Apple Silicon)
- Xcode CLI tools: `xcode-select --install`
- Homebrew packages: `brew install coreutils ninja python3`
- Recommended: `brew install sccache` (compilation cache, faster rebuilds)
- Disk: ~100GB free (source + build artifacts)

## Commands

```sh
just pull              # sync fork with upstream
just setup             # download source, apply patches, configure toolchain
just install           # compile and install to /Applications
just install --force   # clean build from scratch
just version           # show current chromium version
just clean             # remove build source to reclaim disk (~60-80GB)
```

## Workflows

```sh
# first time
just pull
just setup
just install

# update to new chromium version
just pull
just install --force

# rebuild after GN flag tweak
just install

# reclaim disk space
just clean
```

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `JOBS` | all logical CPUs | ninja parallelism |
| `CHROMIUM_ARCHIVE` | `~/.local/share/ungoogled-chromium/archives` | old version archive location |
