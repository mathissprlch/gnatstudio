# Building

## Local (macOS)

Prerequisites:

* macOS 11 or newer (the bundle's `LSMinimumSystemVersion`).
* Xcode Command Line Tools (`xcode-select --install`).
* Rust stable (matches Zed's `rust-toolchain.toml` after fetch).
* Python 3.11+ on PATH.
* `cmake`, `ninja`, `pkg-config`, `rsync` (via Homebrew).

```sh
cd zed-fork
make fetch        # shallow clones upstream Zed at the pinned commit
make patch        # applies patches/*.patch and copies extension into Zed tree
make toolchain    # provisions GNAT, ALS, gnatprove, gdb, RecordFlux into build/
make app          # builds Zed (~30–60 min cold) and assembles Zed GNAT.app
```

`make all` runs the whole pipeline.

After the build the bundle lives at:

```
zed-fork/vendor/zed/target/<triple>/release/bundle/osx/Zed GNAT.app
```

Launch it with `open` or drag it to `/Applications/`.

## Continuous Integration

`.github/workflows/zed-gnat-mac.yml` runs the same pipeline for
`aarch64-apple-darwin` (macos-14) and `x86_64-apple-darwin` (macos-13).
Each job uploads a `.app.tar.gz` (and `.dmg` if signing was configured).

### Required GitHub Secrets (optional, for signed builds)

| Secret                     | Purpose                                              |
| -------------------------- | ---------------------------------------------------- |
| `APPLE_SIGNING_IDENTITY`   | e.g. `Developer ID Application: My Org (TEAMID)`     |
| `APPLE_ID`                 | Notarization Apple ID                                |
| `APPLE_APP_PASSWORD`       | App-specific password for the Apple ID               |
| `APPLE_TEAM_ID`            | Developer team ID                                    |

If these are absent, the build still completes; the resulting `.app`
is unsigned (users must right-click → Open the first time).

## Bumping the Zed pin

1. Edit `zed-fork/zed.pin` with the new commit.
2. `make fetch && make patch` and resolve any patch rejects under
   `zed-fork/vendor/zed/`.
3. If you had to edit upstream files, regenerate the affected patch:

   ```sh
   cd zed-fork/vendor/zed
   git diff -- <path> > ../../patches/<NN-name>.patch
   ```

4. `make app` to make sure the bundle still builds.
5. Commit the updated `zed.pin` + patches.

## Bumping the toolchain

`scripts/provision-toolchain.sh` resolves Alire crates with no version
pins, so re-running `make toolchain` picks up the latest
`gnat_native`, `ada_language_server`, `spark2014`. For
reproducibility, add explicit versions to `stage_crate` calls (e.g.
`stage_crate gnat_native=14.2.1`).

The macOS arm64 builds depend on Alire 2.x having binaries for that
architecture; older Alire versions only supported x86_64.
