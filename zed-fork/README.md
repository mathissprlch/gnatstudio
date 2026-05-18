# Zed GNAT

A fork of [Zed](https://zed.dev) preloaded with the GNAT/SPARK/RecordFlux
toolchain so Ada developers get a working `.app` on macOS with one
download.

## What you get

| Capability                          | Delivered by                                                         |
| ----------------------------------- | -------------------------------------------------------------------- |
| Ada / SPARK syntax highlighting     | `tree-sitter-ada`, wired by the bundled extension                    |
| GPR project file highlighting       | `tree-sitter-gpr`, wired by the bundled extension                    |
| Semantic lookup, completion, refs   | Ada Language Server (ALS) via LSP                                    |
| Code navigation, formatting         | ALS (`gnatformat`) via LSP                                           |
| Debugging Ada programs              | `gdb -i dap` exposed as the `GNAT` DAP adapter (or `codelldb`)       |
| Running the SPARK prover            | `gnatprove`, invoked through a thin proof LSP                        |
| Coverage-style proof results        | Proof LSP publishes per-VC LSP diagnostics → Zed gutter + inline UI  |
| Generating Ada from `.rflx`         | `rflx generate`, invoked through a thin RecordFlux LSP               |
| Self-contained macOS installer      | `Zed GNAT.app` produced in CI; ships ALS, gnatprove, rflx and gdb    |

## Layout

```
zed-fork/
├── Makefile                Build entrypoints (fetch / patch / toolchain / app)
├── zed.pin                 Upstream Zed commit this fork builds against
├── extensions/ada/         Zed extension: language, LSP, DAP, proof LSP, rflx LSP
├── patches/                Patches against the pinned Zed commit
├── scripts/                fetch-zed, apply-patches, bundle-mac, provision-toolchain
├── bundle/                 entitlements.plist (and future Info.plist additions)
├── docs/                   Architecture, building, configuration, licensing
└── vendor/zed/             gitignored; populated by `make fetch`
```

## Quick start

On a Mac with Xcode command-line tools and Rust installed:

```sh
cd zed-fork
make all                    # fetch + patch + toolchain + build
open vendor/zed/target/*/release/bundle/osx/"Zed GNAT.app"
```

The build takes ~30–60 minutes from cold. CI does the same thing for
both Apple Silicon and Intel; see
[`.github/workflows/zed-gnat-mac.yml`](../.github/workflows/zed-gnat-mac.yml).

## Configuration

Everything proof- and tool-related is configurable per workspace. The
default user settings template (`zed-fork/patches/0002-…patch`) ships
commented-out blocks you can uncomment. The same keys work in
`.zed/settings.json` inside any project.

See [`docs/configuration.md`](docs/configuration.md) for the full
matrix (proof level, mode, timeout, RecordFlux target language, etc.).

## Documentation

* [Architecture](docs/architecture.md) — how the pieces fit together.
* [Building](docs/building.md) — local builds + CI overview.
* [Configuration](docs/configuration.md) — every knob and where to set it.
* [Licensing](docs/licensing.md) — GPL/Apache/AGPL boundaries and what
  shipping a single .app implies.
