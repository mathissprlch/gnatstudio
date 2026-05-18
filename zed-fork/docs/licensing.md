# Licensing

A self-contained `Zed GNAT.app` mixes code under several licenses. The
shipping bundle is **GPL-3.0-or-later** as a whole; every other license
the bundle pulls in is compatible with that.

## License of this fork's own code

Everything under `zed-fork/` that we authored is **GPL-3.0-or-later**
(see [`LICENSE`](../LICENSE)). That matches the upstream license of
the bulk of Zed and of every AdaCore tool we wrap.

We picked GPLv3 (not Apache or MIT) for one reason: the Zed pieces our
extension necessarily links against — `crates/dap`, `crates/editor`,
`crates/extension_host`, `crates/zed` — are GPL-3.0. A more permissive
license on this fork would be misleading because nobody can ship a
proprietary derivative of a GPLed Zed anyway.

## What ships inside the .app

| Component                          | License(s)                          | Source                                                    |
| ---------------------------------- | ----------------------------------- | --------------------------------------------------------- |
| Zed editor core                    | GPL-3.0 + Apache-2.0 (per crate)    | [`zed-industries/zed`](https://github.com/zed-industries/zed) |
| Zed collab server (not bundled)    | AGPL-3.0                            | excluded from the bundle                                  |
| `tree-sitter-ada` grammar          | MIT                                 | [`briot/tree-sitter-ada`](https://github.com/briot/tree-sitter-ada) |
| `tree-sitter-gpr` grammar          | MIT                                 | [`brownts/tree-sitter-gpr`](https://github.com/brownts/tree-sitter-gpr) |
| GNAT FSF compiler (`gnat`)         | GPL-3.0 with GCC Runtime Library Exception | Alire crate `gnat_native`                        |
| GNAT runtime libraries (libgnat)   | GPL-3.0 with GCC Runtime Library Exception | linked at runtime by user programs               |
| `gprbuild`                         | GPL-3.0                             | Alire crate `gprbuild`                                    |
| Ada Language Server                | GPL-3.0                             | Alire crate `ada_language_server`                         |
| SPARK 2014 / `gnatprove`           | GPL-3.0 (FSF version)               | Alire crate `spark2014`                                   |
| Why3 / Alt-Ergo / CVC4 (provers)   | LGPL / Apache / BSD                 | bundled by `spark2014`                                    |
| `gdb`                              | GPL-3.0                             | Homebrew / Alire `gdb`                                    |
| `codelldb` (DAP wrapper for LLDB)  | MIT                                 | GitHub releases                                           |
| RecordFlux                         | AGPL-3.0                            | PyPI `RecordFlux`                                         |
| Bundled Python interpreter         | PSF-2.0                             | Homebrew `python@3.12`                                    |

### The AGPL caveat

RecordFlux is **AGPL-3.0**. AGPL imposes additional obligations on
**network-accessible** uses of the code. As an end-user IDE that runs
on a developer's laptop, `Zed GNAT.app` does not trigger the §13
"network use is distribution" clause, but two scenarios do:

1. If you ever host `Zed GNAT` over a remote-desktop / web frontend
   that lets users edit Ada and run `rflx generate` on a server,
   you need to make your modified RecordFlux source available to
   those remote users.
2. If you build internal tooling on top of RecordFlux that exposes
   its functionality over a network API, the same applies.

For the standard developer-desktop case, AGPL behaves like GPL — you
must ship the source of any modifications you made to RecordFlux
itself, but not the source of your own Ada programs that consume
generated code (the GCC Runtime Library Exception covers the
generated artifacts too).

### The GCC Runtime Library Exception

GNAT's runtime is GPLv3, but the **GCC Runtime Library Exception**
explicitly permits linking compiled user programs against that
runtime without imposing GPL on the user's program. So programs you
build with the bundled GNAT can be released under any license you
choose; only the GNAT runtime itself remains GPL.

This is the standard FSF GNAT model. The AdaCore "GNAT Pro" runtime
is licensed differently and is **not** what this fork ships.

## What this means in practice

| Question                                                       | Answer                                                                                          |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Can I distribute Zed GNAT.app inside my company?               | Yes. GPLv3 lets you redistribute internally and externally.                                     |
| Do I have to publish source?                                   | You must offer the source of Zed GNAT itself (this repo + the vendored Zed commit + patches) to anyone you give the binary to. |
| Do my own Ada programs become GPL because I compiled them with GNAT? | No. The GCC Runtime Library Exception covers that.                                       |
| Can I rebrand the .app and sell it?                            | Yes, GPLv3 permits commercial distribution provided you also ship source and pass the GPL on.   |
| Can I host the .app on a website for users to download?        | Yes. Pure distribution does not trigger AGPL's network clause.                                  |
| Can I add proprietary features to Zed GNAT?                    | Only if you keep them as separate processes; in-tree modifications to GPLed crates must remain GPL. |
| Does shipping AGPL RecordFlux inside the .app contaminate the rest? | No. AGPL only adds obligations for code under AGPL — RecordFlux source must be available; the rest stays GPL. |

## What we ship in this repo

* This fork's own source: GPLv3 (`LICENSE`).
* Patches against Zed: GPLv3 (derive from GPLv3 originals).
* Tree-sitter queries (`*.scm`) we authored: MIT, matching the upstream
  grammars they target. The grammars themselves are pulled at build
  time by Zed's extension builder under their own MIT terms.
* The proof and RecordFlux LSPs in `extensions/ada/{proof_lsp,rflx_lsp}/`:
  GPLv3 (they invoke GPL/AGPL tools and benefit from being viral).

## Attribution

The `.app` includes a NOTICE file at `Contents/Resources/NOTICE.md`
that lists every bundled component with its upstream URL and license
file. CI generates this from `scripts/provision-toolchain.sh`'s manifest.

## Trademark

"Zed" is a trademark of Zed Industries, Inc. We rebrand the bundle to
"Zed GNAT" so it's distinct, but consult Zed Industries' trademark
policy if you publish builds widely. "GNAT", "GNAT Studio", and
"SPARK" are trademarks of AdaCore.
