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

* `GNAT` — drives `gdb -i dap`. Requires gdb ≥ 14 (shipped in the
  bundle's `tools/bin/gdb`).
* `codelldb` — fallback for Apple Silicon, where gdb's coverage of
  Ada is weaker. Ada-specific gdb features (exception catchpoints by
  name, formatted tagged-record printing) are not available.

Default debug tasks (see `zed/assets/settings/initial_debug_tasks.json`):

```jsonc
{
  "label": "Debug active Ada main (gdb)",
  "adapter": "GNAT",
  "program": "$ZED_GNAT_MAIN",
  "request": "launch",
  "cwd": "$ZED_WORKTREE_ROOT",
  "preLaunchTask": "gprbuild"
}
```

`$ZED_GNAT_MAIN` is resolved by the Ada extension to the executable
that ALS reports for the active `Main` attribute of the loaded GPR.
If you have multiple mains, override `program` in `.zed/debug.json`.

## Tasks

`zed/assets/settings/initial_tasks.json` ships:

| Label                          | Command                                                       |
| ------------------------------ | ------------------------------------------------------------- |
| `gprbuild`                     | `gprbuild -P $ZED_GPR_FILE -j0 -cargs -gnata -g`              |
| `gprclean`                     | `gprclean -P $ZED_GPR_FILE`                                   |
| `gnatprove (whole project)`    | `gnatprove -P $ZED_GPR_FILE --level=2 --report=all`           |
| `gnatprove (current file)`    | `gnatprove -P $ZED_GPR_FILE -u $ZED_FILENAME --level=2 --report=all` |
| `rflx generate`                | `rflx generate --target ada --output-directory generated $ZED_FILE` |
| `rflx check (current file)`    | `rflx check $ZED_FILE`                                        |

`$ZED_GPR_FILE` resolves to the first `.gpr` at the worktree root.
Override per project by adding the same labels (with different args)
to `.zed/tasks.json`.

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
