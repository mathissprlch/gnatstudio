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

## `lldb-ada-array-bounds.patch` (M1)

GNAT emits array subranges with only `DW_AT_upper_bound`; the default lower
bound is language-defined (1 for Ada, 0 for C). `DWARFASTParser` assumed 0, so
`array (1 .. 3)` rendered with a junk 4th element. This defaults the lower bound
to 1 for Ada compilation units (an explicit `DW_AT_lower_bound` still
overrides). Touches the shared `DWARFASTParser.cpp`, gated on the Ada language,
so it is independent of the M0 patch and applies on top.

## `lldb-ada-variant-records.patch` (M2)

GNAT emits Ada discriminated records using the standard `DW_TAG_variant_part`,
which `DWARFASTParserClang` only consumed for Rust enums — so the `case`
alternatives were dropped and a record showed only its fixed fields. Adds
`ParseAdaVariantPart` to flatten each alternative's member onto the record
(union-like overlap via LLDB's explicit layout). The active alternative now
renders with the correct value (e.g. `g_val = 2.5`). All alternatives are shown
for now; hiding the inactive ones needs a discriminant-aware formatter (later).

## `lldb-ada-subrange-types.patch` (M2)

GNAT emits Ada subtypes (`Natural`, `Positive`, user integer ranges) and the
bound members of unconstrained-array fat pointers as standalone
`DW_TAG_subrange_type` DIEs used directly as a variable's type. LLDB only
handled subranges inside arrays, so a standalone one errored ("unhandled type
tag") and spilled into the Variables pane. Route it through `ParseTypeModifier`
as a typedef of its base type; subtypes now render with values (e.g.
`(natural) len = 10`). Showing an unconstrained array's *content* (fat pointer →
string/slice) still needs the AdaLanguage formatter.

## `lldb-ada-fixed-point.patch` (M2)

GNAT with `-fgnat-encodings=minimal` emits ordinary and decimal fixed-point types
as `DW_TAG_base_type` with `DW_ATE_signed_fixed`/`DW_ATE_unsigned_fixed` plus
`DW_AT_binary_scale` (power of two) or `DW_AT_decimal_scale` (power of ten). LLDB's
Clang type system has no fixed-point type, so these encodings hit the `default:`
arm of `GetBuiltinTypeForDWARFEncodingAndBitSize` and produced an invalid type —
the variable did not render at all. This resolves them to the underlying integer
of the same size, so the value renders (as its raw stored integer); a follow-up
`AdaLanguage` formatter reads the scale and prints the real (scaled) value. These
are standard DWARF encodings, so resolving them is safe for non-Ada units too.

## `lldb-ada-z-fixed-point-scale.patch` (M2)

Builds on `lldb-ada-fixed-point.patch` to render Ada fixed-point with the
actual *scaled* value. The earlier patch made the type resolve (`bf = 40`,
`m = 1999`); this one turns those into `bf = 2.5` and `m = 19.99`.

The DWARF scale (`DW_AT_binary_scale` for ordinary fixed, `DW_AT_decimal_scale`
for decimal fixed) is captured in `ParsedDWARFTypeAttributes` and applied at
the base-type parse site. lldb's Clang AST deduplicates builtin integers (one
`ShortTy`/`IntTy`/`LongLongTy` singleton per AST), so the scale cannot be keyed
on the underlying integer's `QualType` without poisoning plain
`Short_Integer`/`Long_Long_Integer` values. The patch wraps each fixed-point
base in its own Clang typedef (`CreateTypedef`, named after the GNAT base
type), giving it a unique `QualType`; the scale is stored in `TypeSystemAda`
keyed on that typedef. The `AdaLanguage` formatter walks the value's typedef
chain one hop at a time (not via canonical, which would skip past the
fixed-point typedef back to bare `short`/`int`) and applies
`raw * 2^binary_scale` or `raw * 10^decimal_scale` at render time.

Named with a `z` prefix so it sorts last in the patches glob — it depends on
both `lldb-ada-typesystem-ada.patch` (creates `TypeSystemAda`) and
`lldb-ada-language-plugin.patch` (creates `AdaLanguage`).

## `lldb-ada-language-plugin.patch` (M1/M2)

A dedicated `AdaLanguage` plugin registered for `DW_LANG_Ada*`, plus its first
data formatter. It registers the language (source-file detection, entry point,
identity) and adds a hardcoded summary that renders a GNAT unconstrained array
of characters (`String`) as its text. GNAT lays an unconstrained array out as a
*fat pointer* record — `P_ARRAY` (pointer to the data) + `P_BOUNDS` (pointer to
an `{LB0, UB0}` bounds record). The summary matches that shape (restricted to
1-byte character elements, so non-character arrays are left alone), reads the
exact `LB0..UB0` byte range, and prints it quoted: a `String` that used to show
`{ P_ARRAY=.. P_BOUNDS=.. }` now renders as e.g. `"Hello, Ada"` (children
hidden). Auto-registers via the PLUGIN cmake keyword + `LLDB_PLUGIN_DEFINE`, so
no SystemInitializer edit is needed. Requires
`lldb-ada-formatter-routing.patch` to be consulted under M0. Remaining
follow-ups: hide inactive variant alternatives via the discriminant, Ada-style
names, 1-based indices.

## `lldb-ada-formatter-routing.patch` (M0 bridge)

Under M0, Ada types are rendered through `TypeSystemClang`, so a value reports
its language as C/C++ and `FormatManager` only consults the C++/ObjC categories
— never Ada, so the plugin's summaries above would never fire. This adds
`eLanguageTypeAda95` to the candidate-language list for C/C++ values. The Ada
matchers key off GNAT's `P_ARRAY`+`P_BOUNDS` shape, so genuine C/C++ values are
unaffected. **Temporary**: delete once a dedicated `TypeSystemAda` reports
`eLanguageTypeAda*` directly.

### Building

`scripts/build-lldb-ada.sh` clones the pinned LLVM commit, applies every patch
in this directory, and builds `liblldb`:

```sh
zed-fork/scripts/build-lldb-ada.sh                        # Release, AArch64;X86
LLDB_ENABLE_PYTHON=OFF zed-fork/scripts/build-lldb-ada.sh # quick compile-check
```

Then repackage codelldb around it with `scripts/repackage-codelldb.sh` (macOS),
which downloads codelldb v1.11.5 (also LLDB 19.1.x, so ABI-compatible), swaps in
our dylib under the exact name its adapter links, and ad-hoc re-signs both:

```sh
LIBLLDB=zed-fork/build/lldb-ada/liblldb OUTDIR=/tmp/codelldb-ada \
  zed-fork/scripts/repackage-codelldb.sh
```

CI does the build + repackage automatically and uploads the result as the
`codelldb-ada-aarch64` artifact (a `.vsix`). Point
`scripts/provision-toolchain.sh` at it via `CODELLDB_DIST=/path/to/foo.vsix`
(or an unpacked dir) to bundle it instead of upstream. If you fetched the
artifact through a browser, clear quarantine first:
`xattr -dr com.apple.quarantine <path>`.

The result is a codelldb whose `extension/adapter/codelldb` loads our patched
`liblldb`. `scripts/provision-toolchain.sh` will prefer a codelldb found at
`$CODELLDB_DIST` (a directory or VSIX) if that variable is set, so CI can feed
in the patched build; otherwise it falls back to the upstream release.

### Roadmap beyond M0

M0 reuses `TypeSystemClang`. M1+ replaces it with a dedicated
`TypeSystemAda` + `DWARFASTParserAda` + `AdaLanguage` so variant records,
fixed-point, tagged types, and Ada syntax render correctly. Those land as
additional patches/source trees here and should be upstreamed to LLVM.
