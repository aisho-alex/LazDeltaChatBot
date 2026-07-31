.PHONY: deps build run clean clean-deps help

RPC_VERSION ?= v2.57.0

# FPC: by default we look for fpcupdeluxe in a few well-known locations
# and prefer its compiler over the system fpc (which on many distros is
# too old and lacks fcl-process). Override on the command line to point
# at any other fpc binary or fpcupdeluxe tree root.
FPCUP_CANDIDATES := \
  /home/alexander/fpcupdeluxe_trunc/fpc \
  $(HOME)/fpcupdeluxe_trunc/fpc \
  /opt/fpcupdeluxe*/fpc
FPC_ROOT := $(firstword $(wildcard $(FPCUP_CANDIDATES)))
FPC      ?= $(if $(FPC_ROOT),$(FPC_ROOT),fpc)

# If FPC is a directory (fpcupdeluxe tree root), pick the inner fpc.
FPC_BIN := $(if $(wildcard $(FPC)/bin/.*),$(firstword $(wildcard $(FPC)/bin/*/fpc)),$(FPC))

# FPC_UNITS: when using an fpcupdeluxe tree, point at its units dirs so
# fcl-process etc. resolve. When using system fpc, rely on its own
# search paths.
FPC_UNITS ?= $(if $(FPC_ROOT),\
  $(FPC_ROOT)/units/$(shell uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')/rtl \
  $(FPC_ROOT)/units/$(shell uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')/rtl-objpas \
  $(FPC_ROOT)/units/$(shell uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')/fcl-json \
  $(FPC_ROOT)/units/$(shell uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')/fcl-base \
  $(FPC_ROOT)/units/$(shell uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')/fcl-process \
  $(FPC_ROOT)/units/$(shell uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')/pthreads \
,)

help:
	@echo "Targets:"
	@echo "  make deps       - download deltachat-rpc-server ($(RPC_VERSION)) for the host platform"
	@echo "  make build      - compile echobot (depends on deps)"
	@echo "  make run        - build and run echobot with DC_RPC_SERVER pointing at .deps/"
	@echo "  make clean      - remove built binary and intermediate files"
	@echo "  make clean-deps - also remove downloaded deltachat-rpc-server"
	@echo ""
	@echo "Detected:"
	@echo "  FPC_ROOT  = $(FPC_ROOT)"
	@echo "  FPC       = $(FPC)"
	@echo "  FPC_BIN   = $(FPC_BIN)"
	@echo "  FPC_UNITS = $(FPC_UNITS)"
	@echo ""
	@echo "Override on the command line, e.g.:"
	@echo "  RPC_VERSION=v2.58.0 make deps"
	@echo "  FPC=/some/other/fpc make build"

# ---- dependency: deltachat-rpc-server ----
deps:
	@RPC_VERSION=$(RPC_VERSION) ./scripts/fetch-deltachat-rpc-server.sh

# ---- compile Pascal bot ----
build: deps
ifdef FPC_UNITS
	$(FPC_BIN) $(addprefix -Fu,$(FPC_UNITS)) echobot.lpr
else
	$(FPC_BIN) echobot.lpr
endif

# ---- run with auto-detected rpc-server path ----
run: build
	@RPC_VERSION=$(RPC_VERSION) \
	 DC_RPC_SERVER=$$(./scripts/fetch-deltachat-rpc-server.sh --print-path) \
	 ./echobot

clean:
	rm -f echobot *.o *.ppu *.rsj

clean-deps: clean
	rm -rf .deps
