# Building

The upstream Zed source lives at `zed-fork/zed/` (a squashed git
subtree). Building means running Zed's own build through that path.

## Local (macOS)

Prerequisites:

* macOS 11 or newer (the bundle's `LSMinimumSystemVersion`).
* Xcode Command Line Tools (`xcode-select --install`).
* Rust stable (matches Zed's `rust-toolchain.toml` in the subtree).
* Python 3.11+ on PATH.
* `cmake`, `ninja`, `pkg-config`, `rsync` (via Homebrew).

```sh
cd zed-fork
make toolchain    # provisions GNAT, ALS, gnatprove, gdb, RecordFlux into build/
make app          # builds Zed (~30–60 min cold) and assembles Zed GNAT.app
```

`make all` runs both. After the build the bundle lives at:

```
zed-fork/zed/target/<triple>/release/bundle/osx/Zed GNAT.app
```

Launch it with `open` or drag it to `/Applications/`.

## Continuous Integration

`.github/workflows/zed-gnat-mac.yml` runs the same pipeline for
`aarch64-apple-darwin` (macos-14) and `x86_64-apple-darwin` (macos-13).
Each job uploads a `.app.tar.gz` (and `.dmg` if signing was configured).

The workflow uses `fetch-depth: 0` because subtree commits aren't
reachable from a shallow clone.

### Required GitHub Secrets (optional, for signed builds)

| Secret                     | Purpose                                              |
| -------------------------- | ---------------------------------------------------- |
| `APPLE_SIGNING_IDENTITY`   | e.g. `Developer ID Application: My Org (TEAMID)`     |
| `APPLE_ID`                 | Notarization Apple ID                                |
| `APPLE_APP_PASSWORD`       | App-specific password for the Apple ID               |
| `APPLE_TEAM_ID`            | Developer team ID                                    |

If these are absent, the build still completes; the resulting `.app`
is unsigned (users must right-click → Open the first time).

## Editing inside the subtree

`zed-fork/zed/` is just files in this repo. Use any editor; commit
normally:

```sh
$EDITOR zed-fork/zed/crates/zed/Cargo.toml
git add zed-fork/zed/crates/zed/Cargo.toml
git commit -m "Bump bundle min macOS to 12.0"
```

The Zed source itself has a `CLAUDE.md` at `zed-fork/zed/CLAUDE.md`
that documents Zed's own Rust conventions; follow them when modifying
core crates.

## Pulling upstream

```sh
make pull-upstream                       # tracks zed-industries/zed main
make pull-upstream REF=v0.207.4          # a tag
```

See [`upstream-sync.md`](upstream-sync.md) for the conflict workflow
and the list of files most likely to clash.

## Bumping the toolchain

`scripts/provision-toolchain.sh` resolves Alire crates with no version
pins, so re-running `make toolchain` picks up the latest
`gnat_native`, `ada_language_server`, `spark2014`. For
reproducibility, add explicit versions to `stage_crate` calls (e.g.
`stage_crate gnat_native=14.2.1`).

The macOS arm64 builds depend on Alire 2.x having binaries for that
architecture; older Alire versions only supported x86_64.
