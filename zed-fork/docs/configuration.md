# Configuration

All Ada/SPARK/RecordFlux behaviour is configurable. Defaults below mirror
common SPARK practice; nothing is hard-coded into the binary, so you can
override any of these per-workspace in `.zed/settings.json` or globally
in `~/.config/zed/settings.json`.

## Ada Language Server

```jsonc
{
  "lsp": {
    "ada_language_server": {
      "binary": { "path": "/abs/path/to/ada_language_server" }, // optional
      "settings": {
        "ada": {
          "projectFile": "transports_spark.gpr",
          "scenarioVariables": { "BUILD": "Debug", "OS": "unix" },
          "defaultCharset": "UTF-8",
          "enableDiagnostics": true,
          "enableIndexing": true,
          "renameInComments": false,
          "followSymlinks": false,
          "documentationStyle": "gnat",      // "gnat" | "leading" | "itp"
          "onTypeFormatting": { "indentOnly": false },
          "foldComments": true,
          "useGnatformat": true,
          "useCompletionSnippets": true
        }
      }
    }
  }
}
```

`projectFile` is the only setting you usually need to set. The
extension auto-discovers `*.gpr` files at the worktree root if you
leave it empty, but a multi-project repo benefits from pinning it
explicitly.

## SPARK prover (`gnatprove_proof`)

Every flag here maps to a `gnatprove` CLI option. Tuning these is the
main customization point — there is no one-size-fits-all SPARK
configuration.

```jsonc
{
  "lsp": {
    "gnatprove_proof": {
      "settings": {
        "gnatprove": {
          "level": 2,                 // 0..4, --level=N
          "mode": "all",              // all | check | check_all | flow | prove
                                      // | stone | bronze | silver | gold | platinum
          "report": "all",            // all | fail | provers | statistics
          "warnings": "continue",     // continue | error | off
          "timeout": 60,              // per-VC seconds; --timeout=N
          "memlimit": 2000,           // MB per prover; --memlimit=N
          "steps": 0,                 // VC step limit, 0 = unlimited
          "checksOnly": false,        // --checks-only-for-info
          "noAxiomGuard": false,      // --no-axiom-guard
          "noSubprogramVariant": false,
          "proofWarnings": true,      // emit info on unjustified pragmas etc.
          "counterexamples": true,    // --counterexamples=on
          "autoRerunOnSave": false,   // re-run on every save (heavy)
          "extraArgs": []             // raw extra CLI tokens, last wins
        }
      }
    }
  }
}
```

Recommended starting points:

| Workflow                                  | `level` | `timeout` | `mode`  | `autoRerunOnSave` |
| ----------------------------------------- | ------- | --------- | ------- | ----------------- |
| Editing while exploring proofs            | 1       | 30        | `all`   | false             |
| Pre-commit local validation               | 2       | 60        | `all`   | false             |
| CI-style full proof                       | 4       | 300       | `all`   | n/a               |
| Flow analysis only (fast)                 | 0       | 10        | `flow`  | true              |

### Commands

The proof LSP exposes these via `workspace/executeCommand`. They're
bound to default Zed task labels (see `zed/assets/settings/initial_tasks.json`),
so they show up in the command palette under "task: spawn":

* `gnatprove.run` — run on the full project
* `gnatprove.runFile` — run on the active file (`-u`)
* `gnatprove.clean` — `gnatprove --clean`
* `gnatprove.report` — return the last run's totals

## RecordFlux (`recordflux`)

```jsonc
{
  "lsp": {
    "recordflux": {
      "settings": {
        "recordflux": {
          "generate": {
            "language": "ada",          // currently only Ada is supported
            "outputDir": "generated",   // relative to workspace root
            "prefix": "",               // e.g. "App.Wire" to package-prefix output
            "integration": true,        // emit *.rfi integration files
            "debug": false              // pass --debug to rflx generate
          },
          "check": {
            "autoOnSave": true          // re-check the active file on save
          }
        }
      }
    }
  }
}
```

Commands:

* `recordflux.check` — pass arguments are the URIs to check
* `recordflux.generate` — generate Ada from the supplied .rflx URIs
* `recordflux.generateAll` — generate from every .rflx in the workspace

## Debugging

Two adapters are declared by the extension:

* `codelldb` — the working default on macOS. Bundled at
  `tools/codelldb/` and symlinked to `tools/bin/codelldb`. Gives
  breakpoints, stepping, call stack, and registers today. **Ada
  *variable* rendering is not yet available** with stock codelldb — see
  `lldb-ada-debugging.md` for why and the roadmap to fix it.
* `GNAT` — drives `gdb -i dap`. gdb has full Ada support but is only
  practical on Linux/Intel or for cross/remote (embedded) targets, not
  native arm64 macOS.

Default debug tasks (see `zed/assets/settings/initial_debug_tasks.json`):

```jsonc
{
  "label": "Debug active Ada main (codelldb)",
  "adapter": "codelldb",
  "program": "$ZED_WORKTREE_ROOT/$ZED_STEM",
  "request": "launch",
  "cwd": "$ZED_WORKTREE_ROOT",
  "preLaunchTask": "gprbuild"
}
```

`program` uses the built-in `$ZED_STEM` (active file name without
extension), assuming the executable is named after the main unit and
lands in the worktree root (`Exec_Dir use "."` in the GPR) — e.g.
debugging `main.adb` runs `./main`. If your GPR puts the executable
elsewhere or you have multiple mains, override `program` in
`.zed/debug.json`. (The earlier `$ZED_GNAT_MAIN` placeholder was never
resolved by Zed and has been removed.)

## Tasks

`zed/assets/settings/initial_tasks.json` ships the tasks below. Each
discovers the project's `.gpr` at runtime (first `*.gpr` in the worktree
root, where tasks run) rather than relying on an unresolved custom
variable:

| Label                          | Effective command                                            |
| ------------------------------ | ------------------------------------------------------------- |
| `gprbuild`                     | `gprbuild -P <found.gpr> -j0 -cargs -g -gnata -fgnat-encodings=minimal` |
| `gprclean`                     | `gprclean -P <found.gpr>`                                     |
| `gnatprove (whole project)`    | `gnatprove -P <found.gpr> --level=2 --report=all`            |
| `gnatprove (current file)`    | `gnatprove -P <found.gpr> -u $ZED_FILENAME --level=2 --report=all` |
| `rflx generate`                | `rflx generate --target ada --output-directory generated $ZED_FILE` |
| `rflx check (current file)`    | `rflx check $ZED_FILE`                                        |

`-fgnat-encodings=minimal` makes GNAT emit standard DWARF 5, which is a
prerequisite for the LLDB Ada type-system work (see
`lldb-ada-debugging.md`). Override per project by adding the same labels
(with explicit `-P your_project.gpr`) to `.zed/tasks.json`.

## A worked example — `transports-spark`-style project

```jsonc
// .zed/settings.json
{
  "lsp": {
    "ada_language_server": {
      "settings": {
        "ada": {
          "projectFile": "transports_spark.gpr",
          "scenarioVariables": { "BUILD": "Debug" }
        }
      }
    },
    "gnatprove_proof": {
      "settings": {
        "gnatprove": {
          "level": 4,
          "timeout": 120,
          "mode": "all",
          "autoRerunOnSave": false
        }
      }
    },
    "recordflux": {
      "settings": {
        "recordflux": {
          "generate": {
            "prefix": "Transports.Wire",
            "outputDir": "src/generated"
          }
        }
      }
    }
  }
}
```

If you share `transports-spark`'s `.gpr`, `alire.toml`, or any
existing `.als.json`, I can mirror its exact defaults here rather than
the placeholder values.
