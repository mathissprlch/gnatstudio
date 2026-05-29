# Architecture

The fork is a Zed git subtree (`zed-fork/zed/`) plus a small set of
direct modifications committed on top:

* a bundled extension at `zed/extensions/ada/`
* renamed Mac bundle metadata in `zed/crates/zed/Cargo.toml`
* GNAT-flavored defaults in `zed/assets/settings/initial_*.json`
* `extensions/ada` registered in `zed/Cargo.toml` workspace members

Everything else (build pipeline, toolchain provisioning, Mac bundling,
licensing docs) lives outside the subtree under `zed-fork/`. That
separation is the point of the layout — when we pull upstream Zed,
only the subtree is touched.

```
                       ┌─────────────────────────┐
                       │       Zed GNAT.app      │
                       │                         │
   user opens .adb ──▶ │  Contents/MacOS/zed     │ (launcher: sets PATH,
                       │      ↓                  │  ZED_GNAT_RESOURCES)
                       │  Contents/MacOS/zed-real│ (the real Zed binary,
                       │      ↓                  │  built from the subtree)
                       │  Contents/Resources/    │
                       │    extensions/ada/      │ (built-in extension)
                       │    tools/bin/           │ (alr-provisioned GNAT,
                       │      ada_language_server│  gnatprove, rflx, gdb,
                       │      gnatprove          │  codelldb, python3)
                       │      rflx               │
                       │      gdb                │
                       │    tools/python/        │ (vendored RecordFlux
                       │      lib/python*/...    │  Python package)
                       │    tools/lib/           │ (GNAT runtime .dylibs)
                       └─────────────┬───────────┘
                                     │
                  ┌──────────────────┼─────────────────┐
                  │                  │                 │
        spawns LSP:                spawns LSP:    spawns LSP:
        ada_language_server        gnatprove_proof recordflux
        (binary)                   (python wrapper) (python wrapper)
                  │                  │                 │
        textDocument/* + workspace/* events flow through normal LSP
                  │                  │                 │
              navigate, complete, format, hover  diagnostics → gutter
                                  │
                            "coverage style"
                            Hint=green, Warn=yellow, Err=red
```

## Why the proof "coverage overlay" is just diagnostics

The user-visible requirement is *"immersive showing of the results in a
code coverage style fashion"*. Zed already paints per-line gutter
indicators and inline diagnostics in colors driven by severity. So
instead of modifying Zed's editor rendering, the `gnatprove_proof` LSP
emits one diagnostic per Verification Condition:

| VC status (gnatprove output) | LSP severity            | Gutter color (default theme) |
| ---------------------------- | ----------------------- | ---------------------------- |
| `info: ... proved`           | `Hint` (4)              | green                        |
| `warning: ... not proved`    | `Warning` (2)           | yellow                       |
| `error:` (counterexample)    | `Error` (1)             | red                          |
| `info: skipped`/`trivial`    | `Information` (3)       | blue                         |

`diagnostics.inline.enabled = true` (set in our `initial_user_settings.json`)
puts the message next to the line. The visual is equivalent to GNAT
Studio's proof view, but uses Zed's existing renderer.

## Why three LSPs?

Splitting concerns:

* **ALS** owns navigation, completion, formatting, hover, refactors,
  rename, and "regular" GNAT diagnostics. It is unchanged from
  upstream AdaCore; we just point Zed at it.
* **`gnatprove_proof`** wraps GNATprove. It only re-runs on save (when
  the user opts in via `autoRerunOnSave`) and on explicit commands.
  Run cycles can be minutes long, so we don't bolt them into ALS.
* **`recordflux`** wraps the RecordFlux CLI. `.rflx` files do not
  flow through ALS so they need their own server for diagnostics and
  for the `recordflux.generate` command.

## Why we don't change Zed's editor crates

The bigger surface area we touch in `zed/crates/`, the more upstream
pulls hurt. The current divergence is:

| File                                              | Type of change             |
| ------------------------------------------------- | -------------------------- |
| `zed/Cargo.toml`                                  | add `extensions/ada` member |
| `zed/crates/zed/Cargo.toml`                       | branding metadata          |
| `zed/assets/settings/initial_user_settings.json`  | seed user settings         |
| `zed/assets/settings/initial_tasks.json`          | append GNAT task examples  |
| `zed/assets/settings/initial_debug_tasks.json`    | append GNAT debug examples |
| `zed/extensions/ada/**`                           | new directory, no conflict surface |

That's it. Everything else uses Zed's stable extension and LSP
contracts. If we ever need a dedicated proof view (project-wide VC
list, prover statistics graph), Zed's project-diagnostics view already
does the "all VCs grouped by file" case for free, since we publish
diagnostics through the standard channel.

## Toolchain provisioning

`scripts/provision-toolchain.sh` is the boundary between "Zed source"
and "actual GNAT binaries". It uses Alire (`alr`) as a reproducible
binary provider for `gnat_native`, `ada_language_server`, `gprbuild`,
and `spark2014`. RecordFlux is a Python package, so it goes into a
vendored venv. The staged tree is what `bundle-mac.sh` copies into
`Contents/Resources/tools/`.

The launcher in `Contents/MacOS/zed` prepends `tools/bin` to PATH and
exports `ZED_GNAT_RESOURCES`, which the Ada extension uses to find the
bundled binaries before falling back to whatever the user has on PATH.
This means the bundle works without any prerequisites, but a user who
prefers their own Alire-managed toolchain just has to put it earlier
on PATH inside the terminal Zed launches.
