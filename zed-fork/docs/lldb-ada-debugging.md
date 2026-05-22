# Debugging Ada on macOS with LLDB

This document records why Ada variable inspection does not work out of the
box on Apple Silicon, what we ship to make debugging usable today, and the
roadmap to full Ada value rendering.

## TL;DR

* Breakpoints, stepping, and registers work with stock LLDB/codelldb because
  that machinery is language-agnostic (DWARF line tables + DWARF unwind).
* **Local/argument variables do not render** because LLDB has no type system
  for the Ada language codes (`DW_LANG_Ada83/95/2005/2012`). This is a hard
  gap in upstream LLVM, not a configuration mistake.
* gdb has full Ada support but is effectively unavailable for *native*
  `aarch64-apple-darwin` debugging (no working Darwin/arm64 process-control
  backend, plus code-signing entitlement friction). gdb shines for the
  **cross/remote** embedded case (JTAG, gdbserver-over-Ethernet), which is a
  separate, well-supported workflow.
* So on a Mac host debugging a Mac target, the path to real Ada variables is
  an **LLDB Ada type system** — see "Roadmap".

## Empirical findings

Stopped at a breakpoint in `_ada_main`, stock LLDB reports:

```
warning: This version of LLDB has no plugin for the language "ada95".
         Inspection of frame variables will be limited.

(lldb) frame variable           # -> (empty)
(lldb) p Counter                # -> error: Could not find type system for
                                #            language ada95: TypeSystem for
                                #            language ada95 doesn't exist
(lldb) settings set target.language c
(lldb) frame variable           # -> still (empty)
(lldb) p Counter                # -> error: use of undeclared identifier
                                #    note: Ran expression as 'ISO C++'
(lldb) image lookup -v -a $pc   # -> shows CompileUnit/LineEntry/Symbol,
                                #    but NO `Variable:` section
```

| Capability                              | Status  | Why |
|-----------------------------------------|---------|-----|
| Breakpoints, stepping, registers        | works   | DWARF line table + unwind, language-agnostic |
| Variables pane / `frame variable` / `p` | blocked | needs a type system for `ada95` |
| LLDB enumerating vars from DWARF        | blocked | materializing a `Variable` resolves its type → needs type system |
| DWARF data present in build             | yes     | `-g` emits it (on macOS into `.o` / `.dSYM`, see below) |

Key conclusions:

1. `settings set target.language c` only redirects the **expression
   evaluator**; it does not change the per-compilation-unit DWARF type-system
   selection, which keys off `DW_AT_language`. So it does not surface frame
   variables.
2. Because LLDB will not even build `Variable` objects for Ada units, an
   external "Python data formatter" approach has nothing to attach to. Any
   no-fork approach must parse DWARF itself and use LLDB purely as a
   process-control engine (read registers, read memory).

## macOS debug-info layout (debug map vs dSYM)

On macOS the linker does **not** embed DWARF in the executable. `-g` leaves
DWARF in the `.o` files and records a "debug map" in the executable. LLDB
follows the debug map to the `.o` files automatically — which is why it knows
line numbers and the source language even though `dwarfdump main` shows
nothing. To inspect DWARF directly, point tools at the object files or a
`.dSYM`:

```
dwarfdump --name counter obj/main.o      # object file has the real DWARF
# or
dsymutil main && dwarfdump --name counter main.dSYM
```

Implication for distribution: a shipped binary debugged on a machine without
the `obj/` tree needs a `.dSYM` bundle (or embedded DWARF). For local builds
the debug map → `.o` path is sufficient.

## What we ship today

* **Bundled codelldb** (`scripts/provision-toolchain.sh`) so the GNAT debug
  scenarios can actually launch. This gives working breakpoints, stepping,
  call stack, and registers immediately — the ~80% of debugging that does not
  depend on Ada type rendering.
* **`-fgnat-encodings=minimal`** in the default `gprbuild` task. This makes
  GNAT emit standard DWARF 5 (variant parts, dynamic bounds) instead of
  gdb-only GNAT encodings. It is a no-op for *stock* LLDB (no Ada type system
  regardless) but is a prerequisite for the type-system work below, so we set
  it now to avoid a flag-day later.
* **Launch wiring that resolves** without relying on unimplemented custom
  variables — the tasks discover the project `.gpr` at runtime and the debug
  `program` derives from the active file stem. See `configuration.md`.

## Roadmap to real Ada variables

Two paths; we are pursuing Path A because it is the only one that makes the
native Variables pane work and it composes with the broader Ada-on-LLVM
direction (`docs/ada-on-llvm.md`).

### Path A — LLDB Ada type system (fork, then upstream)

Strategic decision: **consume `-fgnat-encodings=minimal` (standard DWARF 5),
do not reverse-engineer legacy GNAT encodings.** That turns "clone gdb's Ada
support" into "write a focused DWARF5 → Ada type system."

Milestones:

* **M0 — language→type-system mapping.** Make `TypeSystemClang` advertise the
  `DW_LANG_Ada*` codes (`TypeSystemClangSupportsLanguage` +
  `GetSupportedLanguagesForTypes`) so the PluginManager routes Ada units to it
  instead of `GetTypeSystemForLanguage(ada95)` erroring — the same shim LLDB
  already uses for Rust and D. DWARF records/arrays/scalars then parse as if C
  (names C-flavored like `pkg__counter`, variant records imperfect). Verified
  to apply and compile against release/19.x; see
  `patches/lldb-ada-typesystem.patch`.
* **M1 — core types** via a real `DWARFASTParserAda`: scalars, modular types,
  enums, constrained arrays, plain records, access types.
* **M2 — Ada aggregates:** unconstrained arrays (array descriptors), variant
  records via `DW_TAG_variant_part`/`DW_AT_discr`, fixed-point scaling,
  enumeration representation clauses.
* **M3 — tagged types:** a `LanguageRuntimeAda` for class-wide dynamic typing.
* **M4 — expression evaluation:** `Obj.Field`, `X'Length`, `X'First`,
  `'Image` (largest, deferrable; a restricted member-access evaluator covers
  most day-to-day use).

Type-system and language plugins are **not** runtime-loadable in LLDB, so
this requires building a custom `liblldb` and repackaging it as our codelldb.
The end state should be upstreamed to LLVM (RFC + review, ideally coordinated
with AdaCore) to escape perpetual fork maintenance.

### Path B — external DWARF reader (no fork)

Parse the binary's DWARF (`llvm-dwarfdump`/`pyelftools`), evaluate each
local's `DW_AT_location` against the stopped frame's registers (via LLDB's
SB API), read memory, and format. This is "write the symbolic half of a
debugger in Python." Viable without a fork but substantial, and it duplicates
work the type system would do natively. Kept as a fallback only.

## Cross / embedded debugging (separate, gdb-friendly)

For embedded targets (Cortex-M via JTAG/OpenOCD, Cortex-A via JTAG or
gdbserver-over-Ethernet) the right tool is a **cross gdb** (`arm-eabi-gdb`,
`aarch64-elf-gdb`, …). A cross gdb runs on the Mac host as an ordinary app —
it speaks the Remote Serial Protocol to the target and never does native
macOS process control, so it sidesteps every native-arm64-darwin gdb problem
and keeps full Ada support. This is tracked separately; see
`docs/embedded-debugging.md` when implemented.
