#!/usr/bin/env python3
"""Minimal LSP server that wraps GNATprove and publishes per-VC results as
diagnostics so Zed renders them in the gutter (the "coverage-style" overlay).

Severity mapping (drives the gutter color and the inline icon):
    proved      -> DiagnosticSeverity.Hint        (4) -- green dot in Zed
    unproved    -> DiagnosticSeverity.Warning     (2) -- yellow
    failed      -> DiagnosticSeverity.Error       (1) -- red
    skipped     -> DiagnosticSeverity.Information (3) -- blue

The server is intentionally dependency-free (stdlib only) so it works against
whatever Python ships in the .app bundle.

Configuration is taken from `initializationOptions.gnatprove` and merged on top
of the defaults in `extension.toml`. Every `textDocument/didSave` re-runs
gnatprove on the saved file's project, unless `autoRerunOnSave` is false.

Custom commands exposed via `workspace/executeCommand`:
    gnatprove.run         - run on the whole project
    gnatprove.runFile     - run scoped to the active file (`-u <file>`)
    gnatprove.clean       - `gnatprove --clean`
    gnatprove.report      - return the parsed report so the client can show it
"""
from __future__ import annotations

import json
import logging
import os
import shlex
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

LOG = logging.getLogger("gnatprove-lsp")

GNATPROVE = os.environ.get("ZED_GNAT_GNATPROVE", "gnatprove")

SEVERITY_HINT = 4
SEVERITY_INFO = 3
SEVERITY_WARNING = 2
SEVERITY_ERROR = 1


@dataclass
class ProofSettings:
    level: int = 2
    mode: str = "all"          # all|check|check_all|flow|prove|stone|bronze|silver|gold|platinum
    report: str = "all"        # all|fail|provers|statistics
    warnings: str = "continue" # continue|error|off
    timeout: int = 60
    memlimit: int = 2000
    steps: int = 0
    checks_only: bool = False
    no_axiom_guard: bool = False
    no_subprogram_variant: bool = False
    proof_warnings: bool = True
    counterexamples: bool = True
    auto_rerun_on_save: bool = False
    extra_args: list[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "ProofSettings":
        s = cls()
        for key, dst in [
            ("level", "level"),
            ("mode", "mode"),
            ("report", "report"),
            ("warnings", "warnings"),
            ("timeout", "timeout"),
            ("memlimit", "memlimit"),
            ("steps", "steps"),
            ("checksOnly", "checks_only"),
            ("noAxiomGuard", "no_axiom_guard"),
            ("noSubprogramVariant", "no_subprogram_variant"),
            ("proofWarnings", "proof_warnings"),
            ("counterexamples", "counterexamples"),
            ("autoRerunOnSave", "auto_rerun_on_save"),
            ("extraArgs", "extra_args"),
        ]:
            if key in d:
                setattr(s, dst, d[key])
        return s

    def to_argv(self, project: Path, scope: list[str] | None) -> list[str]:
        argv: list[str] = [
            GNATPROVE,
            "-P", str(project),
            f"--level={self.level}",
            f"--mode={self.mode}",
            f"--report={self.report}",
            f"--warnings={self.warnings}",
            f"--timeout={self.timeout}",
            f"--memlimit={self.memlimit}",
            f"--steps={self.steps}",
            "--output=brief",
            "--no-counterexample" if not self.counterexamples else "--counterexamples=on",
            "--no-axiom-guard" if self.no_axiom_guard else None,
            "--no-subprogram-variant" if self.no_subprogram_variant else None,
            "--checks-only-for-info" if self.checks_only else None,
            "--no-proof-warnings" if not self.proof_warnings else None,
        ]
        argv = [a for a in argv if a is not None]
        if scope:
            for f in scope:
                argv.extend(["-u", f])
        argv.extend(self.extra_args)
        return argv


class JsonRpc:
    """Length-prefixed JSON-RPC over stdio."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._stdin = sys.stdin.buffer
        self._stdout = sys.stdout.buffer

    def read(self) -> dict | None:
        headers: dict[str, str] = {}
        while True:
            line = self._stdin.readline()
            if not line:
                return None
            line = line.decode("ascii").strip()
            if not line:
                break
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip()] = v.strip()
        length = int(headers.get("Content-Length", "0"))
        if length <= 0:
            return None
        body = self._stdin.read(length)
        return json.loads(body)

    def write(self, msg: dict) -> None:
        data = json.dumps(msg).encode("utf-8")
        header = f"Content-Length: {len(data)}\r\n\r\n".encode("ascii")
        with self._lock:
            self._stdout.write(header)
            self._stdout.write(data)
            self._stdout.flush()


class ProofServer:
    def __init__(self) -> None:
        self.rpc = JsonRpc()
        self.settings = ProofSettings()
        self.root: Path | None = None
        self.project: Path | None = None
        self.last_report: dict[str, Any] = {}
        self.shutting_down = False

    # -- discovery ---------------------------------------------------------

    def detect_project(self) -> Path | None:
        if self.project and self.project.exists():
            return self.project
        if not self.root:
            return None
        gprs = sorted(self.root.glob("*.gpr"))
        # Prefer the one whose name matches the directory; ignore generated.
        name = self.root.name
        for p in gprs:
            if p.stem.lower() == name.lower():
                self.project = p
                return p
        if gprs:
            self.project = gprs[0]
            return gprs[0]
        return None

    # -- gnatprove --------------------------------------------------------

    def run_gnatprove(self, scope: list[str] | None) -> tuple[int, str, str]:
        project = self.detect_project()
        if project is None:
            return 2, "", "no .gpr found in workspace root"
        argv = self.settings.to_argv(project, scope)
        LOG.info("running: %s", shlex.join(argv))
        try:
            proc = subprocess.run(
                argv,
                cwd=self.root or project.parent,
                capture_output=True,
                text=True,
                timeout=max(self.settings.timeout * 8, 300),
            )
        except FileNotFoundError:
            return 127, "", f"gnatprove binary not found: {GNATPROVE}"
        except subprocess.TimeoutExpired as exc:
            return 124, exc.stdout or "", "gnatprove timed out"
        return proc.returncode, proc.stdout, proc.stderr

    def parse_brief(self, stdout: str) -> dict[str, list[dict]]:
        """gnatprove --output=brief writes one line per VC. Format:
            file.adb:LINE:COL: medium|info|warning|error: message
        We treat any "info: proved" as a green hint, "warning: not proved" as
        yellow, "error" as red, and anything else as blue.
        """
        per_file: dict[str, list[dict]] = {}
        for raw in stdout.splitlines():
            line = raw.strip()
            if not line:
                continue
            parts = line.split(":", 4)
            if len(parts) < 5:
                continue
            fname, line_s, col_s, kind, message = parts
            try:
                lineno = max(int(line_s) - 1, 0)
                col = max(int(col_s) - 1, 0)
            except ValueError:
                continue
            kind = kind.strip().lower()
            msg = message.strip()
            severity = SEVERITY_HINT
            label = "proved"
            if "not proved" in msg or kind == "warning":
                severity = SEVERITY_WARNING
                label = "unproved"
            if kind == "error":
                severity = SEVERITY_ERROR
                label = "failed"
            if kind == "info" and "proved" in msg:
                severity = SEVERITY_HINT
                label = "proved"
            if "skipped" in msg or "trivial" in msg:
                severity = SEVERITY_INFO
                label = "skipped"
            entry = {
                "range": {
                    "start": {"line": lineno, "character": col},
                    "end":   {"line": lineno, "character": col + 1},
                },
                "severity": severity,
                "source": "gnatprove",
                "code": label,
                "message": msg,
            }
            abs_path = self._resolve(fname)
            per_file.setdefault(abs_path, []).append(entry)
        return per_file

    def _resolve(self, fname: str) -> str:
        p = Path(fname)
        if not p.is_absolute() and self.root:
            p = (self.root / fname).resolve()
        return f"file://{p}"

    # -- LSP plumbing -----------------------------------------------------

    def publish(self, uri: str, diags: list[dict]) -> None:
        self.rpc.write({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {"uri": uri, "diagnostics": diags},
        })

    def publish_all(self, per_file: dict[str, list[dict]]) -> None:
        for uri, diags in per_file.items():
            self.publish(uri, diags)

    def reply(self, request_id: Any, result: Any = None, error: dict | None = None) -> None:
        msg: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
        if error is not None:
            msg["error"] = error
        else:
            msg["result"] = result
        self.rpc.write(msg)

    # -- request dispatch -------------------------------------------------

    def handle(self, msg: dict) -> None:
        method = msg.get("method")
        params = msg.get("params") or {}
        rid = msg.get("id")

        if method == "initialize":
            self.on_initialize(rid, params)
        elif method == "initialized":
            pass
        elif method == "shutdown":
            self.shutting_down = True
            self.reply(rid, None)
        elif method == "exit":
            sys.exit(0 if self.shutting_down else 1)
        elif method == "workspace/didChangeConfiguration":
            self._apply_settings(params.get("settings", {}))
        elif method == "textDocument/didOpen":
            uri = params.get("textDocument", {}).get("uri", "")
            self._maybe_run([uri])
        elif method == "textDocument/didSave":
            uri = params.get("textDocument", {}).get("uri", "")
            if self.settings.auto_rerun_on_save:
                self._maybe_run([uri])
        elif method == "workspace/executeCommand":
            self.on_command(rid, params)
        elif rid is not None:
            self.reply(rid, error={"code": -32601, "message": f"method not found: {method}"})

    def on_initialize(self, rid: Any, params: dict) -> None:
        root_uri = params.get("rootUri") or ""
        if root_uri.startswith("file://"):
            self.root = Path(root_uri[7:])
        opts = (params.get("initializationOptions") or {}).get("gnatprove") or {}
        self.settings = ProofSettings.from_dict(opts)
        self.reply(rid, {
            "capabilities": {
                "textDocumentSync": 1,
                "executeCommandProvider": {
                    "commands": [
                        "gnatprove.run",
                        "gnatprove.runFile",
                        "gnatprove.clean",
                        "gnatprove.report",
                    ]
                },
            },
            "serverInfo": {"name": "gnatprove-lsp", "version": "0.1.0"},
        })

    def _apply_settings(self, settings: dict) -> None:
        gp = (settings or {}).get("gnatprove") or {}
        if gp:
            self.settings = ProofSettings.from_dict(gp)

    def on_command(self, rid: Any, params: dict) -> None:
        cmd = params.get("command")
        args = params.get("arguments") or []
        if cmd == "gnatprove.run":
            self._maybe_run(None)
            self.reply(rid, self.last_report)
        elif cmd == "gnatprove.runFile":
            files = [a for a in args if isinstance(a, str)]
            self._maybe_run(files)
            self.reply(rid, self.last_report)
        elif cmd == "gnatprove.clean":
            project = self.detect_project()
            if project is None:
                self.reply(rid, error={"code": -32603, "message": "no .gpr found"})
                return
            subprocess.run([GNATPROVE, "-P", str(project), "--clean"], check=False)
            self.reply(rid, {"ok": True})
        elif cmd == "gnatprove.report":
            self.reply(rid, self.last_report)
        else:
            self.reply(rid, error={"code": -32601, "message": f"unknown command: {cmd}"})

    def _maybe_run(self, scope_uris: list[str] | None) -> None:
        scope_files: list[str] | None = None
        if scope_uris:
            scope_files = []
            for u in scope_uris:
                if u.startswith("file://"):
                    scope_files.append(Path(u[7:]).name)
        rc, out, err = self.run_gnatprove(scope_files)
        per_file = self.parse_brief(out)
        # Clear stale diagnostics for files we ran against but got no output for.
        if scope_files and self.root:
            for f in scope_files:
                uri = self._resolve(f)
                per_file.setdefault(uri, [])
        self.publish_all(per_file)
        totals = {"proved": 0, "unproved": 0, "failed": 0, "skipped": 0}
        for diags in per_file.values():
            for d in diags:
                totals[d["code"]] = totals.get(d["code"], 0) + 1
        self.last_report = {
            "returnCode": rc,
            "totals": totals,
            "stderr": err.strip(),
        }
        self.rpc.write({
            "jsonrpc": "2.0",
            "method": "window/showMessage",
            "params": {
                "type": 3,  # Info
                "message": (
                    f"GNATprove: {totals['proved']} proved, "
                    f"{totals['unproved']} unproved, "
                    f"{totals['failed']} failed, "
                    f"{totals['skipped']} skipped"
                ),
            },
        })

    def serve(self) -> None:
        while True:
            try:
                msg = self.rpc.read()
            except Exception as exc:
                LOG.exception("read failed: %s", exc)
                return
            if msg is None:
                return
            try:
                self.handle(msg)
            except Exception as exc:
                LOG.exception("handle failed: %s", exc)
                rid = msg.get("id")
                if rid is not None:
                    self.reply(rid, error={"code": -32603, "message": str(exc)})


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("ZED_GNAT_LOG", "WARNING"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    ProofServer().serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
