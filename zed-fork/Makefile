# Zed GNAT fork build entrypoints.
#
# Day-to-day flow (on macOS):
#   make fetch       -- shallow-clone upstream Zed at the pinned commit
#   make patch       -- apply our patches + drop the extension in-tree
#   make toolchain   -- stage GNAT/SPARK/RecordFlux into build/toolchain/
#   make app         -- build Zed and assemble Zed GNAT.app
#
# CI shortcut:
#   make ci-mac      -- runs everything end-to-end.
#
# Variables you can override:
#   TARGET_TRIPLE     default: host triple
#   RELEASE_CHANNEL   default: stable
#   TOOLCHAIN_DIR     default: $(PWD)/build/toolchain
#   SIGNING_IDENTITY  if set, codesign + (optionally) notarize the bundle

SHELL := /bin/bash
ROOT  := $(shell pwd)

RELEASE_CHANNEL ?= stable
TOOLCHAIN_DIR   ?= $(ROOT)/build/toolchain
TARGET_TRIPLE   ?=

export RELEASE_CHANNEL
export TOOLCHAIN_DIR
export TARGET_TRIPLE

.PHONY: all fetch patch toolchain app clean refresh-patches ci-mac

all: fetch patch toolchain app

fetch:
	bash scripts/fetch-zed.sh

patch: fetch
	bash scripts/apply-patches.sh

toolchain:
	bash scripts/provision-toolchain.sh

app: patch toolchain
	bash scripts/bundle-mac.sh

# Re-generate patches from in-tree changes you made under vendor/zed/.
# Useful when iterating on a patch interactively.
refresh-patches:
	@if [[ ! -d vendor/zed/.git ]]; then \
	  echo "vendor/zed not present; run make fetch first" >&2; exit 1; \
	fi
	@echo "Diffing vendor/zed against the pin; pipe into the right patch file manually."
	cd vendor/zed && git diff

ci-mac: fetch patch toolchain app

clean:
	rm -rf vendor/zed/target build
