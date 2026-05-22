# LLDB / codelldb patches

These patches add Ada support to the LLDB that ships inside codelldb. See
`../docs/lldb-ada-debugging.md` for the full rationale and roadmap.

## `lldb-ada-typesystem.patch` (M0)

Routes `DW_LANG_Ada*` compilation units through LLDB's Clang type system so
local variables render at all. This is the minimum change that turns an empty
Variables pane into one showing scalars, arrays, and records.

It is two edits to `TypeSystemClang.cpp`, and both matter:
`TypeSystemClangSupportsLanguage` (so `CreateInstance` accepts Ada units) and
`GetSupportedLanguagesForTypes` (so the PluginManager actually *routes* Ada
units to Clang — adding only the first does nothing). Verified to apply and
compile against `release/19.x` at
`cd708029e0b2869e80abe31ddb175f7c35361f90`.

Type-system plugins are compiled into `liblldb`; they cannot be loaded at
runtime. So using this patch means **building a custom `liblldb` and
repackaging codelldb around it**.

### Building

`scripts/build-lldb-ada.sh` clones the pinned LLVM commit, applies every patch
in this directory, and builds `liblldb`:

```sh
zed-fork/scripts/build-lldb-ada.sh                        # Release, AArch64;X86
LLDB_ENABLE_PYTHON=OFF zed-fork/scripts/build-lldb-ada.sh # quick compile-check
```

Then repackage codelldb (github.com/vadimcn/codelldb) against the resulting
`liblldb`: point its Rust adapter build at it, or swap the dylib inside a
prebuilt codelldb VSIX's `extension/lldb/lib/` and re-sign. Set `$CODELLDB_DIST`
to that build so `scripts/provision-toolchain.sh` bundles it instead of the
upstream release.

The result is a codelldb whose `extension/adapter/codelldb` loads our patched
`liblldb`. `scripts/provision-toolchain.sh` will prefer a codelldb found at
`$CODELLDB_DIST` (a directory or VSIX) if that variable is set, so CI can feed
in the patched build; otherwise it falls back to the upstream release.

### Roadmap beyond M0

M0 reuses `TypeSystemClang`. M1+ replaces it with a dedicated
`TypeSystemAda` + `DWARFASTParserAda` + `AdaLanguage` so variant records,
fixed-point, tagged types, and Ada syntax render correctly. Those land as
additional patches/source trees here and should be upstreamed to LLVM.
