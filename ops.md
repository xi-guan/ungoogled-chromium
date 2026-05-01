# Operations Guide

## Prerequisites

- macOS (Apple Silicon)
- Xcode CLI tools: `xcode-select --install`
- Homebrew packages: `brew install coreutils ninja python3`
- Recommended: `brew install sccache` (compilation cache, faster rebuilds)
- Disk: ~100GB free (source + build artifacts)

## Common Commands

```sh
just build          # full build: download, patch, compile, install to /Applications
just rebuild        # incremental: skip download/patch, just recompile + install
just clean-build    # delete build source and start from scratch
just clean          # remove build source to reclaim disk (~60-80GB)
just version        # show current chromium version
just size           # show Chromium.app build output size
just archives       # list archived old versions
just clean-archives # remove old archives (keeps latest 3 by default)
just cache-stats    # show sccache hit/miss stats
```

## Build Flow

```
just build
  -> clone ungoogled-chromium-macos (first time only)
  -> download source (~30GB tarball)
  -> unpack, prune binaries, apply patches, domain substitution
  -> configure (GN, arm64, sccache, ThinLTO)
  -> compile (ninja, all cores)
  -> sign + install to /Applications
  -> auto-delete download cache (~5GB saved)
```

Previous versions are archived to `~/.local/share/ungoogled-chromium/archives/`.

## Disk Space Management

After a successful build, download cache is automatically cleaned.

To reclaim the bulk of disk space (build source + artifacts):

```sh
just clean    # removes build/src (~60-80GB), next build will be full
```

## Incremental vs Full Build

| Scenario | Command |
|----------|---------|
| First time or after `just clean` | `just build` |
| Rebuild after GN flag tweak | `just rebuild` |
| Update to new Chromium version | `just pull && just clean-build` |

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `JOBS` | all logical CPUs | ninja parallelism |
| `CHROMIUM_ARCHIVE` | `~/.local/share/ungoogled-chromium/archives` | old version archive location |
