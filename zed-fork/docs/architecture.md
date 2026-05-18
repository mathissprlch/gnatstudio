# Architecture

The fork is a thin layer on top of upstream Zed. Most of the value comes
from the **bundled extension**; the Zed core patches mostly do branding
and ship sane defaults.

```
                       ┌─────────────────────────┐
                       │       Zed GNAT.app      │
                       │                         │
   user opens .adb ──▶ │  Contents/MacOS/zed     │ (launcher: sets PATH,
                       │      ↓                  │  ZED_GNAT_RESOURCES)
                       │  Contents/MacOS/zed-real│ (the real Zed binary,
                       │      ↓                  │  built from vendored Zed
                       │  Contents/Resources/    │  + our 4 patches)
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
instead of patching Zed core to render a custom proof gutter, the
`gnatprove_proof` LSP emits one diagnostic per Verification Condition:

| VC status (gnatprove output) | LSP severity            | Gutter color (default theme) |
| ---------------------------- | ----------------------- | ---------------------------- |
| `info: ... proved`           | `Hint` (4)              | green                        |
| `warning: ... not proved`    | `Warning` (2)           | yellow                       |
| `error:` (counterexample)    | `Error` (1)             | red                          |
| `info: skipped`/`trivial`    | `Information` (3)       | blue                         |

The user can flip on `diagnostics.inline.enabled` (we already do this in
`patches/0002`) to get the message next to the line. The result is
visually equivalent to GNAT Studio's proof results view, but inherits
Zed's editor performance and theming.

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

## Why we don't patch Zed for the proof view

Patching Zed core has a recurring cost: every Zed bump risks merge
conflicts in the gutter rendering, diagnostic model, or settings
schema. By emitting diagnostics we lean on Zed's stable public LSP
contract.

If we ever need a separate panel ("show all VCs across the project,
grouped by file"), Zed's project-diagnostics view already does this for
free since we publish diagnostics through the standard channel.

## Toolchain provisioning

`scripts/provision-toolchain.sh` is the boundary between "Zed source +
patches" and "actual GNAT binaries". It uses Alire (`alr`) as a
reproducible binary provider for `gnat_native`, `ada_language_server`,
`gprbuild`, and `spark2014`. RecordFlux is a Python package, so it
goes into a vendored venv. The staged tree is what bundle-mac copies
into `Contents/Resources/tools/`.

The launcher in `Contents/MacOS/zed` prepends `tools/bin` to PATH and
exports `ZED_GNAT_RESOURCES`, which the Ada extension uses to find the
bundled binaries before falling back to whatever the user has on PATH.
This means the bundle works without any prerequisites, but a user who
prefers their own Alire-managed toolchain just has to put it earlier
on PATH inside Zed's launched terminal.
