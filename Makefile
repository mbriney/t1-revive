# t1-revive developer targets. Plain GNU make + bash; nothing is built here.
#
#   make quality            lint + scan + test (what CI runs)
#   make lint               bash -n on every shell file, then shellcheck -x
#   make syntax             bash -n only (plus a parse of test/*.bats)
#   make shellcheck         shellcheck -x only
#   make scan               tools/scan-identifiers.sh over the work tree
#   make banned             only the forbidden-ACPI-method check (AGENTS.md rule 1)
#   make test               bats test/            (make test BATS_ARGS=--filter=redact)
#   make hooks              enable the pre-commit hook (identifier scan + bash -n)
#   make devtools-check     which tools are missing and how to get them
#
# shellcheck and bats are looked up in PATH first, then in $(DEVTOOLS)/bin.
# DEVTOOLS defaults to ~/.local/t1-revive-devtools; a user-space install without
# a package manager can live anywhere:  make quality DEVTOOLS=/path/to/devtools
# (bin/shellcheck = static release binary, bin/bats -> bats-core/bin/bats).

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
MAKEFLAGS += --no-builtin-rules --no-print-directory

DEVTOOLS ?= $(HOME)/.local/t1-revive-devtools
export DEVTOOLS

define find_tool
$(or $(shell command -v $(1) 2>/dev/null),$(wildcard $(DEVTOOLS)/bin/$(1)))
endef
SHELLCHECK := $(call find_tool,shellcheck)
BATS       := $(call find_tool,bats)

# Everything that is bash. Missing globs expand to nothing, so this works on the skeleton.
SH_FILES := $(sort $(wildcard bin/t1-revive) \
  $(shell find lib tools contrib .githooks -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null) \
  $(wildcard .githooks/pre-commit build.sh))
BATS_FILES := $(wildcard test/*.bats)
TEST_HELPERS := $(wildcard test/test_helper/*.bash)

.PHONY: all quality lint syntax shellcheck scan banned test hooks devtools-check help

all: help

help:
	@sed -n 's/^#   \(make [a-z-]*\) *\(.*\)/  \1\t\2/p' Makefile

quality: lint scan test

lint: syntax shellcheck

# bash -n on every shell file, plus `bats --count`, which parses the .bats files without
# running them (bats sources them, so a syntax error there shows up as a parse failure).
syntax:
	@rc=0; for f in $(SH_FILES) $(TEST_HELPERS); do bash -n "$$f" || rc=1; done; \
	  if [ -n "$(BATS)" ] && [ -n "$(BATS_FILES)" ]; then \
	    n=$$("$(BATS)" --count $(BATS_FILES)) || { echo "bats could not parse test/*.bats" >&2; rc=1; }; \
	    [ -z "$$n" ] || echo "syntax: $$n bats tests parse"; \
	  fi; \
	  [ $$rc -eq 0 ] && echo "syntax: ok ($(words $(SH_FILES) $(TEST_HELPERS)) shell files)"; exit $$rc

shellcheck:
	@if [ -z "$(SHELLCHECK)" ]; then echo "shellcheck: not found (see: make devtools-check)" >&2; exit 1; fi; \
	  $(SHELLCHECK) --version | sed -n 2p; \
	  $(SHELLCHECK) -x $(SH_FILES) $(TEST_HELPERS) && \
	  echo "shellcheck: ok ($(words $(SH_FILES) $(TEST_HELPERS)) files)"

scan:
	@bash tools/scan-identifiers.sh

banned:
	@bash tools/scan-identifiers.sh --banned-only

test:
	@if [ -z "$(BATS)" ]; then echo "bats: not found (see: make devtools-check)" >&2; exit 1; fi; \
	  $(BATS) --version; $(BATS) $(BATS_ARGS) test/

hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled (core.hooksPath=.githooks)"

devtools-check:
	@echo "DEVTOOLS=$(DEVTOOLS)"; missing=0; \
	  for t in shellcheck bats iasl jq flock logger; do \
	    p=$$(command -v $$t 2>/dev/null || true); [ -n "$$p" ] || [ ! -x "$(DEVTOOLS)/bin/$$t" ] || p="$(DEVTOOLS)/bin/$$t"; \
	    if [ -n "$$p" ]; then printf '  %-10s %s\n' "$$t" "$$p"; else printf '  %-10s MISSING\n' "$$t"; missing=1; fi; \
	  done; \
	  if [ $$missing -eq 1 ]; then echo; echo "Install on Arch:   sudo pacman -S shellcheck bats acpica jq util-linux"; \
	    echo "Without root:      put a static shellcheck in \$$DEVTOOLS/bin and a bats-core clone at \$$DEVTOOLS/bats-core"; \
	    echo "                   (ln -s ../bats-core/bin/bats \$$DEVTOOLS/bin/bats); then: make quality DEVTOOLS=/that/dir"; fi
