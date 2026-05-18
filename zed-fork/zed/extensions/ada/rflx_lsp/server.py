#!/usr/bin/env python3
"""Minimal LSP server for RecordFlux .rflx files.

Runs `rflx check` on save, publishes diagnostics, and exposes
`recordflux.generate` as a command (which calls `rflx generate` with the
user-configured target language and output dir).

Like the proof LSP, this is stdlib-only.
"""
from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

LOG = logging.getLogger("recordflux-lsp")
RFLX = os.environ.get("ZED_GNAT_RFLX", "rflx")

# `rflx check` prints diagnostics as:
#   path/to/file.rflx:LINE:COL: error: message
#   path/to/file.rflx:LINE:COL: warning: message
DIAG_RE = re.compile(r"^(?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+):\s*(?P<kind>error|warning|info):\s*(?P<msg>.*)$")

SEVERITY_ERROR = 1
SEVERITY_WARNING = 2
SEVERITY_INFO = 3


@dataclass
class RflxSettings:
    generate_language: str = "ada"
    generate_output_dir: str = "generated"
    generate_prefix: str = ""
    generate_integration: bool = True
    generate_debug: bool = False
    check_auto_on_save: bool = True

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "RflxSettings":
        s = cls()
        gen = d.get("generate") or {}
        chk = d.get("check") or {}
        s.generate_language = gen.get("language", s.generate_language)
        s.generate_output_dir = gen.get("outputDir", s.generate_output_dir)
        s.generate_prefix = gen.get("prefix", s.generate_prefix)
        s.generate_integration = gen.get("integration", s.generate_integration)
        s.generate_debug = gen.get("debug", s.generate_debug)
        s.check_auto_on_save = chk.get("autoOnSave", s.check_auto_on_save)
        return s


class JsonRpc:
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


class RflxServer:
    def __init__(self) -> None:
        self.rpc = JsonRpc()
        self.root: Path | None = None
        self.settings = RflxSettings()
        self.shutting_down = False

    # --- I/O -------------------------------------------------------------

    def reply(self, rid: Any, result: Any = None, error: dict | None = None) -> None:
        msg: dict[str, Any] = {"jsonrpc": "2.0", "id": rid}
        if error is not None:
            msg["error"] = error
        else:
            msg["result"] = result
        self.rpc.write(msg)

    def publish(self, uri: str, diags: list[dict]) -> None:
        self.rpc.write({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {"uri": uri, "diagnostics": diags},
        })

    def notify(self, level: int, message: str) -> None:
        self.rpc.write({
            "jsonrpc": "2.0",
            "method": "window/showMessage",
            "params": {"type": level, "message": message},
        })

    # --- rflx ------------------------------------------------------------

    def check(self, files: list[Path]) -> dict[str, list[dict]]:
        if not files:
            return {}
        argv = [RFLX, "check", *[str(f) for f in files]]
        LOG.info("running: %s", argv)
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        except FileNotFoundError:
            self.notify(1, f"rflx not found at {RFLX}; install via pip or Alire")
            return {f"file://{f}": [] for f in files}
        per_file: dict[str, list[dict]] = {f"file://{f}": [] for f in files}
        for line in (proc.stderr + "\n" + proc.stdout).splitlines():
            m = DIAG_RE.match(line.strip())
            if not m:
                continue
            kind = m["kind"]
            severity = {
                "error": SEVERITY_ERROR,
                "warning": SEVERITY_WARNING,
                "info": SEVERITY_INFO,
            }[kind]
            try:
                ln = max(int(m["line"]) - 1, 0)
                col = max(int(m["col"]) - 1, 0)
            except ValueError:
                continue
            fname = m["file"]
            path = Path(fname)
            if not path.is_absolute() and self.root:
                path = (self.root / fname).resolve()
            uri = f"file://{path}"
            per_file.setdefault(uri, []).append({
                "range": {
                    "start": {"line": ln, "character": col},
                    "end":   {"line": ln, "character": col + 1},
                },
                "severity": severity,
                "source": "rflx",
                "message": m["msg"],
            })
        return per_file

    def generate(self, files: list[Path]) -> dict[str, Any]:
        out_dir = self.settings.generate_output_dir
        if not Path(out_dir).is_absolute() and self.root:
            out_dir = str(self.root / out_dir)
        Path(out_dir).mkdir(parents=True, exist_ok=True)
        argv = [
            RFLX,
            "generate",
            "--target", self.settings.generate_language,
            "--output-directory", out_dir,
        ]
        if self.settings.generate_prefix:
            argv.extend(["--prefix", self.settings.generate_prefix])
        if self.settings.generate_integration:
            argv.append("--integration-files")
        if self.settings.generate_debug:
            argv.append("--debug")
        argv.extend(str(f) for f in files)
        LOG.info("running: %s", argv)
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=600)
        except FileNotFoundError:
            return {"ok": False, "error": f"rflx not found at {RFLX}"}
        return {
            "ok": proc.returncode == 0,
            "returnCode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "outputDir": out_dir,
        }

    # --- dispatch --------------------------------------------------------

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
            cfg = (params.get("settings") or {}).get("recordflux") or {}
            if cfg:
                self.settings = RflxSettings.from_dict(cfg)
        elif method == "textDocument/didOpen":
            uri = params.get("textDocument", {}).get("uri", "")
            self._check_uri(uri)
        elif method == "textDocument/didSave":
            uri = params.get("textDocument", {}).get("uri", "")
            if self.settings.check_auto_on_save:
                self._check_uri(uri)
        elif method == "workspace/executeCommand":
            self.on_command(rid, params)
        elif rid is not None:
            self.reply(rid, error={"code": -32601, "message": f"method not found: {method}"})

    def on_initialize(self, rid: Any, params: dict) -> None:
        root_uri = params.get("rootUri") or ""
        if root_uri.startswith("file://"):
            self.root = Path(root_uri[7:])
        opts = (params.get("initializationOptions") or {}).get("recordflux") or {}
        self.settings = RflxSettings.from_dict(opts)
        self.reply(rid, {
            "capabilities": {
                "textDocumentSync": 1,
                "executeCommandProvider": {
                    "commands": [
                        "recordflux.check",
                        "recordflux.generate",
                        "recordflux.generateAll",
                    ]
                },
            },
            "serverInfo": {"name": "recordflux-lsp", "version": "0.1.0"},
        })

    def on_command(self, rid: Any, params: dict) -> None:
        cmd = params.get("command")
        args = params.get("arguments") or []
        if cmd == "recordflux.check":
            files = [Path(self._uri_to_path(a)) for a in args if isinstance(a, str)]
            for uri, diags in self.check(files).items():
                self.publish(uri, diags)
            self.reply(rid, {"ok": True})
        elif cmd == "recordflux.generate":
            files = [Path(self._uri_to_path(a)) for a in args if isinstance(a, str)]
            self.reply(rid, self.generate(files))
        elif cmd == "recordflux.generateAll":
            if not self.root:
                self.reply(rid, error={"code": -32603, "message": "no workspace root"})
                return
            files = sorted(self.root.rglob("*.rflx"))
            self.reply(rid, self.generate(files))
        else:
            self.reply(rid, error={"code": -32601, "message": f"unknown command: {cmd}"})

    def _check_uri(self, uri: str) -> None:
        if not uri.startswith("file://"):
            return
        path = Path(uri[7:])
        for u, diags in self.check([path]).items():
            self.publish(u, diags)

    def _uri_to_path(self, uri: str) -> str:
        return uri[7:] if uri.startswith("file://") else uri

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
    RflxServer().serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
