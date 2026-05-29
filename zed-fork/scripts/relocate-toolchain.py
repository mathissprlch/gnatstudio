#!/usr/bin/env python3
"""Make a macOS toolchain self-contained.

For every Mach-O file under TOOLS_DIR:

* Delete LC_RPATH entries that point to absolute build-machine paths
  (/Users/runner/..., /private/..., /opt/..., /usr/local/..., /tmp/...).
  Recent macOS dyld (Sonoma+) rejects duplicate LC_RPATH entries, and
  Alire's `alr install --prefix=DIR` regularly emits duplicates because
  both the source artifact and the install step add an rpath.
* Ensure `@loader_path/../lib` is present so binaries in bin/ can find
  dylibs in the sibling lib/ directory regardless of where the .app
  is opened from.
* Re-sign each modified file ad-hoc; install_name_tool mutates the
  Mach-O header and invalidates the original signature.

Idempotent: rerunning is a no-op once everything is clean. Only runs
on Darwin; the caller (provision-toolchain.sh) guards.
"""

import re
import subprocess
import sys
from pathlib import Path

# Anything under these prefixes is a build-machine path that has no
# meaning inside the shipped .app. macOS shared libs live under /usr/lib
# and /System/Library which DO exist on the user's machine, so we leave
# those alone.
ABSOLUTE_BLOCKLIST = re.compile(r"^/(Users|private|opt|usr/local|tmp)/")

# Mach-O / fat-binary magic numbers in every byte order we might see.
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",  # MH_MAGIC      (32-bit, BE)
    b"\xce\xfa\xed\xfe",  # MH_CIGAM      (32-bit, LE)
    b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64   (64-bit, BE)
    b"\xcf\xfa\xed\xfe",  # MH_CIGAM_64   (64-bit, LE)
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC
    b"\xbe\xba\xfe\xca",  # FAT_CIGAM
    b"\xca\xfe\xba\xbf",  # FAT_MAGIC_64
    b"\xbf\xba\xfe\xca",  # FAT_CIGAM_64
}

DESIRED_RPATH = "@loader_path/../lib"


def run(*argv, check=False):
    return subprocess.run(argv, check=check, capture_output=True, text=True)


def is_macho(path: Path) -> bool:
    try:
        with open(path, "rb") as fp:
            return fp.read(4) in MACHO_MAGICS
    except OSError:
        return False


_RPATH_RE = re.compile(r"^\s*path (.+) \(offset \d+\)\s*$")


def read_rpaths(path: Path) -> list[str]:
    result = []
    pending = False
    output = run("otool", "-l", str(path)).stdout
    for line in output.splitlines():
        if "cmd LC_RPATH" in line:
            pending = True
            continue
        if pending:
            match = _RPATH_RE.match(line)
            if match:
                result.append(match.group(1))
                pending = False
    return result


def relocate(path: Path) -> bool:
    modified = False

    # Delete every absolute-path LC_RPATH. We re-read after each delete so
    # we naturally handle duplicates (install_name_tool removes one entry
    # per call).
    for victim in {p for p in read_rpaths(path) if ABSOLUTE_BLOCKLIST.match(p)}:
        while victim in read_rpaths(path):
            r = run("install_name_tool", "-delete_rpath", victim, str(path))
            if r.returncode != 0:
                print(
                    f"  delete_rpath {victim!r} failed: {r.stderr.strip()}",
                    file=sys.stderr,
                )
                break
            modified = True

    if DESIRED_RPATH not in read_rpaths(path):
        r = run("install_name_tool", "-add_rpath", DESIRED_RPATH, str(path))
        if r.returncode == 0:
            modified = True
        else:
            print(
                f"  add_rpath {DESIRED_RPATH!r} failed: {r.stderr.strip()}",
                file=sys.stderr,
            )

    if modified:
        r = run("codesign", "--force", "--sign", "-", str(path))
        if r.returncode != 0:
            print(f"  codesign failed: {r.stderr.strip()}", file=sys.stderr)

    return modified


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <tools-dir>", file=sys.stderr)
        return 2

    tools_dir = Path(argv[1]).resolve()
    if not tools_dir.is_dir():
        print(f"{tools_dir}: not a directory", file=sys.stderr)
        return 2

    scanned = 0
    relocated = 0
    for path in tools_dir.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        # codelldb ships self-contained and code-signed; mutating its Mach-O
        # headers would break its signature and its own dylib resolution.
        if "codelldb" in path.parts:
            continue
        if not is_macho(path):
            continue
        scanned += 1
        try:
            if relocate(path):
                relocated += 1
                print(f"relocated: {path.relative_to(tools_dir)}")
        except Exception as exc:  # surface failures, keep going
            print(f"failed {path}: {exc}", file=sys.stderr)

    print(f"relocate-toolchain: scanned {scanned} Mach-O files, modified {relocated}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
