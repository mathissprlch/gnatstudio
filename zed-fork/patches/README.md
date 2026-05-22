# LLDB / codelldb patches

These patches add Ada support to the LLDB that ships inside codelldb. See
`../docs/lldb-ada-debugging.md` for the full rationale and roadmap.

## `lldb-ada-typesystem.patch` (M0)

Routes `DW_LANG_Ada*` compilation units through LLDB's Clang type system so
local variables render at all. This is the minimum change that turns an empty
Variables pane into one showing scalars, arrays, and records.

Type-system plugins are compiled into `liblldb`; they cannot be loaded at
runtime. So using this patch means **building a custom `liblldb` and
repackaging codelldb around it**.

### Build outline (manual, until CI automates it)

```sh
# 1. Get matching sources.
git clone --depth 1 -b release/19.x https://github.com/llvm/llvm-project
git -C llvm-project apply /path/to/zed-fork/patches/lldb-ada-typesystem.patch

# 2. Build liblldb (Release, arm64).
cmake -S llvm-project/llvm -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lldb" \
  -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \
  -DLLDB_ENABLE_PYTHON=ON
ninja -C build liblldb

# 3. Repackage codelldb against this liblldb.
#    codelldb (github.com/vadimcn/codelldb) builds its Rust adapter against a
#    LLDB. Point its build at the liblldb produced above (see codelldb's
#    BUILD docs / LLDB_* env), or swap the liblldb dylib inside a prebuilt
#    codelldb VSIX's extension/lldb/lib/ and re-sign.
```

The result is a codelldb whose `extension/adapter/codelldb` loads our patched
`liblldb`. `scripts/provision-toolchain.sh` will prefer a codelldb found at
`$CODELLDB_DIST` (a directory or VSIX) if that variable is set, so CI can feed
in the patched build; otherwise it falls back to the upstream release.

### Roadmap beyond M0

M0 reuses `TypeSystemClang`. M1+ replaces it with a dedicated
`TypeSystemAda` + `DWARFASTParserAda` + `AdaLanguage` so variant records,
fixed-point, tagged types, and Ada syntax render correctly. Those land as
additional patches/source trees here and should be upstreamed to LLVM.
