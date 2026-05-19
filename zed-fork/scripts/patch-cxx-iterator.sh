#!/usr/bin/env bash
# Patch cxx-build's cxx.h template so rust::Slice<T>::iterator declares
# `using element_type = T;`.
#
# Why: libc++ 17+ (Xcode 15.x) instantiates std::pointer_traits<It> while
# evaluating std::contiguous_iterator<It>, both for the static_assert at
# cxx.h:282-283 and for std::copy()'s __unwrap_range optimization. With no
# element_type typedef on the iterator, libc++'s __pointer_traits_element_type
# helper is undefined and the build fails compiling webrtc-sys's
# livekit/frame_cryptor.h:51 (std::copy(key.begin(), key.end(), ...)).
#
# dtolnay/cxx ships value_type/pointer/reference/difference_type but not
# element_type; this script injects the missing typedef in place. It is a
# no-op if the typedef is already present (e.g. after an upstream fix lands).
#
# We patch the cxx and cxx-build crate sources in cargo's registry cache,
# which is what cxx-build copies into each consumer's OUT_DIR at build time.
# Run this BEFORE `cargo build` so the modified template is what gets used.

set -euo pipefail

REGISTRY_SRC="${CARGO_HOME:-$HOME/.cargo}/registry/src"
if [[ ! -d "$REGISTRY_SRC" ]]; then
  echo "patch-cxx-iterator: no cargo registry at $REGISTRY_SRC; run 'cargo fetch' first" >&2
  exit 1
fi

patched=0
skipped=0
not_found=0
while IFS= read -r -d '' header; do
  if ! grep -q 'class Slice<T>::iterator final' "$header"; then
    continue
  fi
  result=$(python3 - "$header" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
# Only consider the body of Slice<T>::iterator.
iter_class = re.search(
    r"class Slice<T>::iterator final \{(.*?)\n\};",
    text,
    re.DOTALL,
)
if not iter_class:
    print("skip-not-found")
    sys.exit(0)
if "using element_type" in iter_class.group(1):
    print("skip-already-patched")
    sys.exit(0)
pattern = re.compile(
    r"(class Slice<T>::iterator final \{.*?using value_type = T;\n)"
    r"(\s*using difference_type)",
    re.DOTALL,
)
new_text, n = pattern.subn(
    r"\1  using element_type = T;\n\2",
    text,
    count=1,
)
if n != 1:
    sys.exit(f"expected 1 substitution, made {n}")
path.write_text(new_text)
print("patched")
PY
)
  case "$result" in
    patched) patched=$((patched + 1)); echo "patch-cxx-iterator: patched $header" ;;
    skip-already-patched) skipped=$((skipped + 1)) ;;
    skip-not-found) not_found=$((not_found + 1)) ;;
    *) echo "patch-cxx-iterator: unexpected result '$result' for $header" >&2; exit 1 ;;
  esac
done < <(find "$REGISTRY_SRC" \
  -type f \
  \( -path '*/cxx-1.0.*/include/cxx.h' \
     -o -path '*/cxx-build-1.0.*/src/gen/include/cxx.h' \
     -o -path '*/cxxbridge-cmd-1.0.*/src/gen/include/cxx.h' \) \
  -print0)

echo "patch-cxx-iterator: patched=$patched skipped=$skipped not-found=$not_found"
if [[ "$patched" -eq 0 && "$skipped" -eq 0 ]]; then
  echo "patch-cxx-iterator: WARNING — no cxx.h files matched" >&2
  exit 1
fi
