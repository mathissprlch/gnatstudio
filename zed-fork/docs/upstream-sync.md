# Upstream sync

We carry the Zed source as a **squashed git subtree** at `zed-fork/zed/`.
Squashed means our repo only holds one upstream commit at a time, plus
our own commits on top of it. The trade-off:

* (+) Repo stays around 100 MB instead of the multi-GB it would be with
  full upstream history.
* (+) Every change we make to Zed is a normal commit, visible in
  `git log` and reviewable in a PR.
* (−) You cannot blame back into the upstream commit that introduced a
  given line. To do that, browse the upstream repo at the commit
  recorded in the most recent "Squashed `zed-fork/zed/` content from
  commit `<sha>`" message.

## Pulling upstream

```sh
cd zed-fork
make pull-upstream                     # tracks zed-industries/zed main
make pull-upstream REF=v0.207.4        # a tag
make pull-upstream REF=abcdef123456    # a specific commit
```

The script wraps `git subtree pull --prefix=zed-fork/zed --squash` so
the upstream history stays squashed and our diff stays auditable.

### Resolving conflicts

`git subtree pull` produces a regular merge commit. Conflicts are
real overlaps between our changes and upstream's:

```sh
# Inspect the conflicted files
git status
# Edit them; the conflict markers are normal
$EDITOR zed-fork/zed/<file>
git add zed-fork/zed/<file>
git commit            # the merge message is already prepared
```

Common conflict hotspots, ordered by likelihood:

| File / area                                          | Why it conflicts                            |
| ---------------------------------------------------- | ------------------------------------------- |
| `zed/crates/zed/Cargo.toml`                          | Upstream tweaks the `[package.metadata.bundle-*]` blocks we renamed for branding. |
| `zed/assets/settings/initial_user_settings.json`     | Upstream adds new commented examples; we replaced the file with our Ada-flavored version. |
| `zed/assets/settings/initial_tasks.json`             | We appended GNAT tasks. Upstream appends others. |
| `zed/assets/settings/initial_debug_tasks.json`       | Same as above for debug tasks.              |
| `zed/Cargo.toml` (workspace `members`)               | New upstream extensions land here; we added `"extensions/ada"`. |
| `zed/extensions/ada/Cargo.toml`                      | If upstream bumps `zed_extension_api`, bump ours too in the same merge. |

After resolving, run a smoke build:

```sh
make app
```

…to make sure your resolution didn't break compilation.

## Pushing back upstream (if you ever want to)

If a change we made under `zed-fork/zed/` is worth upstreaming, split it
into a branch on a Zed fork:

```sh
cd /path/to/this/repo
git subtree push --prefix=zed-fork/zed \
    git@github.com:<your-zed-fork>/zed.git \
    <branch-with-just-our-change>
```

Subtree push re-derives the per-file history of just `zed-fork/zed/`
onto the target branch, dropping everything outside that prefix. You
can then open a PR against `zed-industries/zed` from that branch.

In practice the bundled extension (`zed/extensions/ada/`) is the only
piece that's plausibly upstreamable — the branding and bundling are
ours by definition. If the extension matures, consider extracting it
to its own repo and registering it in the Zed extension registry
instead of upstreaming through subtree push.

## Pinning, recovering, downgrading

* `git log --oneline --grep "Squashed 'zed-fork/zed/'"` — every prior
  upstream pull as a single line. Includes the upstream commit SHA.
* To roll back to the previous upstream version, revert the most recent
  "Squashed" + "Merge commit" pair.
* To completely re-base on a different upstream pin, the cleanest path
  is to `git rm -r zed-fork/zed` and re-add the subtree at the new SHA;
  this discards our changes inside the subtree, so do it on a branch
  and replay our edits.
