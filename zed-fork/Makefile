# Zed GNAT fork build entrypoints.
#
# The upstream Zed source lives at zed-fork/zed/ as a squashed git
# subtree. All our changes (branding, default settings, the bundled
# Ada extension) are normal commits in this repo.
#
# Day-to-day flow (on macOS):
#   make toolchain   -- stage GNAT/SPARK/RecordFlux into build/toolchain/
#   make app         -- build Zed and assemble Zed GNAT.app
#
# CI shortcut:
#   make ci-mac      -- runs toolchain + app end-to-end.
#
# Upstream sync:
#   make pull-upstream            -- pull origin/main into the subtree
#   make pull-upstream REF=v0.207 -- pull a specific tag/branch/SHA
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
REF             ?= main

export RELEASE_CHANNEL
export TOOLCHAIN_DIR
export TARGET_TRIPLE

.PHONY: all toolchain app pull-upstream ci-mac clean

all: toolchain app

toolchain:
	bash scripts/provision-toolchain.sh

app: toolchain
	bash scripts/bundle-mac.sh

pull-upstream:
	bash scripts/pull-upstream.sh $(REF)

ci-mac: toolchain app

clean:
	rm -rf zed/target build
