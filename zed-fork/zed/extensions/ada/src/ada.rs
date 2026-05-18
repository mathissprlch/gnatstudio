//! Zed extension entry point for Ada, SPARK, GPR and RecordFlux.
//!
//! This wires three language servers and one DAP adapter into Zed:
//!   * `ada_language_server` — AdaCore's ALS, used for Ada and GPR.
//!   * `gnatprove_proof`     — a thin LSP shim around `gnatprove` that
//!                              publishes per-VC results as diagnostics so
//!                              they render in Zed's gutter (the
//!                              "coverage-style" overlay the user asked for).
//!   * `recordflux`          — a thin LSP shim around `rflx check`/`generate`.
//!   * `GNAT` (DAP)          — drives `gdb -i mi` via the cpptools adapter.
//!
//! All binaries are resolved in this order:
//!   1. A user-configured path from Zed settings (`lsp.<server>.binary.path`).
//!   2. The worktree `$PATH` (so an Alire toolchain in the project wins).
//!   3. The fork's bundled `Resources/tools/bin/` directory inside the .app.
//!   4. A last-resort GitHub release download.

use std::{env, fs, path::PathBuf};

use zed_extension_api::{
    self as zed, DebugAdapterBinary, DebugTaskDefinition, LanguageServerId, Result, Worktree,
    serde_json,
    settings::LspSettings,
};

const ALS_DEFAULT_BIN: &str = "ada_language_server";
const GNATPROVE_BIN: &str = "gnatprove";
const RFLX_BIN: &str = "rflx";
const GDB_BIN: &str = "gdb";

struct AdaExtension {
    cached_als: Option<String>,
    cached_proof_lsp: Option<String>,
    cached_rflx_lsp: Option<String>,
}

impl AdaExtension {
    /// Look in `$ZED_GNAT_RESOURCES/tools/bin` first, then `$PATH`.
    /// The Mac bundle exports `ZED_GNAT_RESOURCES` from the launcher.
    fn locate(worktree: &Worktree, name: &str) -> Option<String> {
        if let Ok(root) = env::var("ZED_GNAT_RESOURCES") {
            let candidate = PathBuf::from(root).join("tools").join("bin").join(name);
            if fs::metadata(&candidate).is_ok_and(|m| m.is_file()) {
                return candidate.to_str().map(str::to_owned);
            }
        }
        worktree.which(name)
    }

    fn als_path(&mut self, worktree: &Worktree) -> Result<String> {
        if let Some(cached) = &self.cached_als
            && fs::metadata(cached).is_ok_and(|m| m.is_file())
        {
            return Ok(cached.clone());
        }
        let path = Self::locate(worktree, ALS_DEFAULT_BIN).ok_or_else(|| {
            "ada_language_server not found. Install it via Alire (`alr install ada_language_server`), \
             let the bundled toolchain provide it, or set `lsp.ada_language_server.binary.path`."
                .to_string()
        })?;
        self.cached_als = Some(path.clone());
        Ok(path)
    }

    /// The proof LSP is a Python script shipped with the extension. We invoke
    /// `python3` on it and let it call `gnatprove` internally.
    fn proof_lsp_command(&mut self, worktree: &Worktree) -> Result<zed::Command> {
        let script = if let Some(cached) = &self.cached_proof_lsp {
            cached.clone()
        } else {
            let p = extension_resource("proof_lsp/server.py")?;
            self.cached_proof_lsp = Some(p.clone());
            p
        };
        let python = Self::locate(worktree, "python3")
            .or_else(|| Self::locate(worktree, "python"))
            .ok_or_else(|| "python3 not found on PATH; required for the GNATprove LSP".to_string())?;
        let gnatprove = Self::locate(worktree, GNATPROVE_BIN).unwrap_or_else(|| GNATPROVE_BIN.into());
        Ok(zed::Command {
            command: python,
            args: vec![script],
            env: vec![("ZED_GNAT_GNATPROVE".into(), gnatprove)],
        })
    }

    fn rflx_lsp_command(&mut self, worktree: &Worktree) -> Result<zed::Command> {
        let script = if let Some(cached) = &self.cached_rflx_lsp {
            cached.clone()
        } else {
            let p = extension_resource("rflx_lsp/server.py")?;
            self.cached_rflx_lsp = Some(p.clone());
            p
        };
        let python = Self::locate(worktree, "python3")
            .or_else(|| Self::locate(worktree, "python"))
            .ok_or_else(|| "python3 not found; required for the RecordFlux LSP".to_string())?;
        let rflx = Self::locate(worktree, RFLX_BIN).unwrap_or_else(|| RFLX_BIN.into());
        Ok(zed::Command {
            command: python,
            args: vec![script],
            env: vec![("ZED_GNAT_RFLX".into(), rflx)],
        })
    }
}

fn extension_resource(rel: &str) -> Result<String> {
    let cwd = env::current_dir().map_err(|e| format!("cwd unavailable: {e}"))?;
    let candidate = cwd.join(rel);
    candidate
        .to_str()
        .map(str::to_owned)
        .ok_or_else(|| format!("non-UTF8 path for {rel}"))
}

impl zed::Extension for AdaExtension {
    fn new() -> Self {
        Self {
            cached_als: None,
            cached_proof_lsp: None,
            cached_rflx_lsp: None,
        }
    }

    fn language_server_command(
        &mut self,
        id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<zed::Command> {
        match id.as_ref() {
            "ada_language_server" => Ok(zed::Command {
                command: self.als_path(worktree)?,
                args: vec![],
                env: Default::default(),
            }),
            "gnatprove_proof" => self.proof_lsp_command(worktree),
            "recordflux" => self.rflx_lsp_command(worktree),
            other => Err(format!("unknown language server id: {other}")),
        }
    }

    fn language_server_workspace_configuration(
        &mut self,
        id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Option<serde_json::Value>> {
        // Forward whatever the user set under `lsp.<id>.settings` in Zed
        // settings, with sane defaults merged underneath.
        let user = LspSettings::for_worktree(id.as_ref(), worktree)
            .ok()
            .and_then(|s| s.settings)
            .unwrap_or_default();

        let defaults = match id.as_ref() {
            "ada_language_server" => serde_json::json!({
                "ada": {
                    "projectFile": "",                  // ALS auto-discovers *.gpr
                    "scenarioVariables": {},
                    "defaultCharset": "UTF-8",
                    "enableDiagnostics": true,
                    "enableIndexing": true,
                    "renameInComments": false,
                    "followSymlinks": false,
                    "documentationStyle": "gnat",
                    "onTypeFormatting": { "indentOnly": false },
                    "foldComments": true,
                    "useGnatformat": true,
                    "useCompletionSnippets": true
                }
            }),
            "gnatprove_proof" => serde_json::json!({
                "gnatprove": {
                    "level": 2,
                    "mode": "all",
                    "report": "all",
                    "warnings": "continue",
                    "timeout": 60,
                    "memlimit": 2000,
                    "steps": 0,
                    "checksOnly": false,
                    "noAxiomGuard": false,
                    "noSubprogramVariant": false,
                    "proofWarnings": true,
                    "counterexamples": true,
                    "autoRerunOnSave": false
                }
            }),
            "recordflux" => serde_json::json!({
                "recordflux": {
                    "generate": {
                        "language": "ada",
                        "outputDir": "generated",
                        "prefix": "",
                        "integration": true,
                        "debug": false
                    },
                    "check": {
                        "autoOnSave": true
                    }
                }
            }),
            _ => return Ok(None),
        };

        Ok(Some(merge_json(defaults, user)))
    }

    // ----- DAP ---------------------------------------------------------------

    fn get_dap_binary(
        &mut self,
        adapter_name: String,
        _config: DebugTaskDefinition,
        user_path: Option<String>,
        worktree: &Worktree,
    ) -> Result<DebugAdapterBinary, String> {
        match adapter_name.as_str() {
            "GNAT" => {
                let gdb = user_path
                    .or_else(|| Self::locate(worktree, GDB_BIN))
                    .ok_or_else(|| {
                        "gdb not found. Install it via Alire (`alr install gnat_native`) or set \
                         `dap.GNAT.binary` in your debug config."
                            .to_string()
                    })?;
                Ok(DebugAdapterBinary {
                    command: Some(gdb),
                    arguments: vec!["-i".into(), "dap".into()],
                    envs: vec![],
                    cwd: None,
                    connection: None,
                    request_args: zed::StartDebuggingRequestArguments {
                        configuration: "{}".into(),
                        request: zed::StartDebuggingRequestArgumentsRequest::Launch,
                    },
                })
            }
            "codelldb" => {
                let bin = user_path
                    .or_else(|| Self::locate(worktree, "codelldb"))
                    .ok_or_else(|| {
                        "codelldb not found. Bundled tools provide it; set `dap.codelldb.binary` to override."
                            .to_string()
                    })?;
                Ok(DebugAdapterBinary {
                    command: Some(bin),
                    arguments: vec!["--port".into(), "0".into()],
                    envs: vec![],
                    cwd: None,
                    connection: None,
                    request_args: zed::StartDebuggingRequestArguments {
                        configuration: "{}".into(),
                        request: zed::StartDebuggingRequestArgumentsRequest::Launch,
                    },
                })
            }
            other => Err(format!("unknown DAP adapter: {other}")),
        }
    }

    fn dap_request_kind(
        &mut self,
        _adapter_name: String,
        config: serde_json::Value,
    ) -> Result<zed::StartDebuggingRequestArgumentsRequest, String> {
        // Both adapters use the standard `request` field.
        match config.get("request").and_then(|v| v.as_str()) {
            Some("attach") => Ok(zed::StartDebuggingRequestArgumentsRequest::Attach),
            Some("launch") | None => Ok(zed::StartDebuggingRequestArgumentsRequest::Launch),
            Some(other) => Err(format!("unknown request kind: {other}")),
        }
    }
}

/// Shallow merge that lets user-provided settings override defaults at the
/// top level. Sufficient for the small nested objects we ship.
fn merge_json(mut base: serde_json::Value, overlay: serde_json::Value) -> serde_json::Value {
    if let (Some(base_map), Some(overlay_map)) = (base.as_object_mut(), overlay.as_object()) {
        for (k, v) in overlay_map {
            match base_map.get_mut(k) {
                Some(slot) if slot.is_object() && v.is_object() => {
                    *slot = merge_json(slot.clone(), v.clone());
                }
                _ => {
                    base_map.insert(k.clone(), v.clone());
                }
            }
        }
    }
    base
}

zed::register_extension!(AdaExtension);
