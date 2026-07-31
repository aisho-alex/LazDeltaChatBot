.PHONY: deps build run clean clean-deps help

RPC_VERSION ?= v2.57.0
# FPC points to either an fpc binary in PATH (default) or to an
# fpcupdeluxe-style tree root (then we use $FPC/bin/<target>/fpc).
# FPC_UNITS is a space-separated list of units paths; when empty,
# fpc's own search paths are used.
FPC         ?= fpc
FPC_UNITS   ?=

# If FPC looks like a directory, append /bin/<host-triple>/fpc.
FPC_BIN := $(if $(wildcard $(FPC)/bin/.*),$(wildcard $(FPC)/bin/*/fpc),$(FPC))

help:
	@echo "Targets:"
	@echo "  make deps       - download deltachat-rpc-server ($(RPC_VERSION)) for the host platform"
	@echo "  make build      - compile echobot (depends on deps)"
	@echo "  make run        - build and run echobot with DC_RPC_SERVER pointing at .deps/"
	@echo "  make clean      - remove built binary and intermediate files"
	@echo "  make clean-deps - also remove downloaded deltachat-rpc-server"
	@echo ""
	@echo "Variables (override on the command line):"
	@echo "  RPC_VERSION=v2.58.0 make deps"
	@echo "  FPC=/path/to/fpcupdeluxe_trunc/fpc FPC_UNITS='/path/rtl /path/fcl-base ...' make build"
	@echo ""
	@echo "Effective FPC binary: $(FPC_BIN)"

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
