#!/usr/bin/env bash
# Pull the latest upstream Zed into the zed-fork/zed/ subtree.
#
# Usage:
#   scripts/pull-upstream.sh            # pull origin/main, squashed
#   scripts/pull-upstream.sh <ref>      # pull a specific ref (tag/branch/SHA)
#
# Conflicts are real — they show our divergence from upstream. Resolve them
# in the normal git workflow (edit, `git add`, `git commit`). The merge
# commit subject is shaped so it's easy to spot in `git log`.
set -euo pipefail

REPO="${ZED_UPSTREAM_REPO:-https://github.com/zed-industries/zed.git}"
REF="${1:-main}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# We have to run subtree from the top of the consuming repo.
cd "$(git -C "${ROOT}" rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree is dirty; commit or stash first" >&2
    exit 1
fi

echo "Pulling ${REF} from ${REPO} into zed-fork/zed/ (squashed)…"
git subtree pull \
    --prefix=zed-fork/zed \
    --squash \
    --message="Pull upstream Zed (${REF})" \
    "${REPO}" "${REF}"

echo
echo "Now run the build (make -C zed-fork app) to confirm nothing broke."
