# Assignment 2: FPGA market maker.
#
#   make           build build/market_maker (run it on a scenario in sim/fixtures/)
#   make verify    run every fixture and check the orders are unchanged
#   make timing    synthesize, place and route the design; print its maximum
#                  clock frequency and resource use (a few minutes)
#   make tools     download and unpack the pinned FPGA toolchain into tools/
#                  (Verilator, Yosys, nextpnr, GTKWave, from the OSS CAD Suite)
#   make test-holes  build and run the unit tests for the four modules you
#                  implement (tests/*_test.cpp) -- faster, more isolated
#                  feedback than make verify while you're working on a hole

# ---------------------------------------------------------------------------
# Toolchain: OSS CAD Suite, pinned to one release so everyone gets the same
# versions (synthesis results and maximum clock frequency vary between
# versions). To upgrade: change OSS_CAD_RELEASE and the four checksums below
# (GitHub lists each archive's SHA-256 on the release page).
# ---------------------------------------------------------------------------

OSS_CAD_RELEASE := 2026-10-14

TOOLS_DIR   := tools
OSS_CAD_DIR := $(TOOLS_DIR)/oss-cad-suite
TOOLS_BIN   := $(abspath $(OSS_CAD_DIR)/bin)

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Linux)
  ifeq ($(UNAME_M),x86_64)
    OSS_CAD_PLATFORM := linux-x64
    OSS_CAD_SHA256   := a6ccc6b96b2d985336a1061c78b2fd2bdd73e0f68690da17db88e00457881a11
  else ifeq ($(UNAME_M),aarch64)
    OSS_CAD_PLATFORM := linux-arm64
    OSS_CAD_SHA256   := ac908e60bbac62673565250c5ca5cd774c5066c440a418bc108d78da1762f86c
  endif
else ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    OSS_CAD_PLATFORM := darwin-arm64
    OSS_CAD_SHA256   := 2dbecc2a8622076e12341132fec9fefd32dad0f10b2fd019172c7c9ad270cda4
  else ifeq ($(UNAME_M),x86_64)
    OSS_CAD_PLATFORM := darwin-x64
    OSS_CAD_SHA256   := 358daf849d1f38d7d343c45a73d72bfb7d280a62615bdbbb7a96c1f061594dc5
  endif
endif

OSS_CAD_ARCHIVE := oss-cad-suite-$(OSS_CAD_PLATFORM)-$(subst -,,$(OSS_CAD_RELEASE)).tgz
OSS_CAD_URL     := https://github.com/YosysHQ/oss-cad-suite-build/releases/download/$(OSS_CAD_RELEASE)/$(OSS_CAD_ARCHIVE)
OSS_CAD_STAMP   := $(OSS_CAD_DIR)/.installed-$(OSS_CAD_RELEASE)

# Every recipe uses the pinned tools first, without changing your shell.
export PATH := $(TOOLS_BIN):$(PATH)

all: build/market_maker

.PHONY: all tools clean-tools verify update-expected timing timing-logs test-holes clean
tools: $(OSS_CAD_STAMP)
	@echo "Toolchain ready ($(OSS_CAD_RELEASE)):"
	@echo "  $$(verilator --version)"
	@echo "  $$(yosys -V)"
	@echo "  $$(nextpnr-ecp5 --version 2>&1 | head -1)"

$(OSS_CAD_STAMP):
	@if [ -z "$(OSS_CAD_PLATFORM)" ]; then \
		echo "error: no OSS CAD Suite build for $(UNAME_S)/$(UNAME_M)." >&2; \
		echo "       On Windows, use WSL2 and run make there." >&2; \
		exit 1; \
	fi
	@mkdir -p $(TOOLS_DIR)
	@echo "Downloading $(OSS_CAD_ARCHIVE) (~500-750 MB)..."
	curl -fL --retry 3 --progress-bar -o $(TOOLS_DIR)/$(OSS_CAD_ARCHIVE).part $(OSS_CAD_URL)
	@echo "Checking SHA-256..."
	@if command -v sha256sum >/dev/null; then \
		actual=$$(sha256sum $(TOOLS_DIR)/$(OSS_CAD_ARCHIVE).part | cut -d' ' -f1); \
	else \
		actual=$$(shasum -a 256 $(TOOLS_DIR)/$(OSS_CAD_ARCHIVE).part | cut -d' ' -f1); \
	fi; \
	if [ "$$actual" != "$(OSS_CAD_SHA256)" ]; then \
		echo "error: checksum mismatch for $(OSS_CAD_ARCHIVE)" >&2; \
		echo "       expected $(OSS_CAD_SHA256)" >&2; \
		echo "       got      $$actual" >&2; \
		rm -f $(TOOLS_DIR)/$(OSS_CAD_ARCHIVE).part; \
		exit 1; \
	fi
	@echo "Unpacking into $(OSS_CAD_DIR)..."
	@rm -rf $(OSS_CAD_DIR)
	tar -xzf $(TOOLS_DIR)/$(OSS_CAD_ARCHIVE).part -C $(TOOLS_DIR)
	@rm -f $(TOOLS_DIR)/$(OSS_CAD_ARCHIVE).part
	@touch $@

clean-tools:
	rm -rf $(TOOLS_DIR)

# ---------------------------------------------------------------------------
# The market maker: the RTL, Verilated, driven by the simulator.
# ---------------------------------------------------------------------------

BUILD := build

# Stops with a clear message if `make tools` hasn't been run, rather than
# falling back to whatever tools happen to be installed on the system.
REQUIRE_TOOLS = @test -f $(OSS_CAD_STAMP) || { echo "error: toolchain not installed; run 'make tools' first" >&2; exit 1; }

VERILATOR_FLAGS := --cc --exe --build -j 0 -Wall -CFLAGS "-std=c++20 -I$(CURDIR)"

# Every RTL source, packages first (they must be read before their users).
RTL_SOURCES := rtl/config_pkg.sv rtl/messages_pkg.sv rtl/pipeline_pkg.sv \
	rtl/market_data_parser.sv rtl/sequence_check.sv rtl/report_parser.sv rtl/merge.sv \
	rtl/order_table.sv rtl/book.sv rtl/pricing.sv rtl/quote_manager.sv \
	rtl/order_encoder.sv rtl/register_bank.sv rtl/market_maker.sv

SIM_SOURCES := sim/messages/format.cpp sim/exchange/order_book.cpp sim/exchange/exchange.cpp \
	sim/replay/scenario.cpp sim/runtime/capture.cpp sim/runtime/simulator.cpp

APP_SOURCES := app/fpga.cpp app/market_maker.cpp app/main.cpp

# --trace compiles in waveform support (used only with --waves).
$(BUILD)/market_maker: $(RTL_SOURCES) $(SIM_SOURCES) $(APP_SOURCES) $(wildcard app/*.h sim/*/*.h)
	$(REQUIRE_TOOLS)
	@mkdir -p $(BUILD)
	@echo "Building $@ (Verilating the RTL; about 20 s)..."
	@verilator $(VERILATOR_FLAGS) --trace -CFLAGS -O2 --top-module market_maker \
		-Mdir $(BUILD)/market_maker_verilated -o $(abspath $@) \
		$(RTL_SOURCES) $(addprefix $(CURDIR)/,$(SIM_SOURCES) $(APP_SOURCES)) > /dev/null

# Scenarios with a recorded expected order stream (<name>.expected).
VERIFY_FIXTURES := $(patsubst %.expected,%,$(wildcard sim/fixtures/*.expected))

# Runs the app on every fixture and checks that its orders are unchanged.
verify: $(BUILD)/market_maker
	@status=0; \
	for f in $(VERIFY_FIXTURES); do \
		name=$$(basename $$f); \
		./$(BUILD)/market_maker $$f.scn --out $(BUILD)/verify/$$name > /dev/null || { status=1; continue; }; \
		if diff -u $$f.expected $(BUILD)/verify/$$name/orders.txt > $(BUILD)/verify/$$name/diff.txt; then \
			echo "PASS $$name"; \
		else \
			echo "FAIL $$name (see $(BUILD)/verify/$$name/diff.txt)"; status=1; \
		fi; \
	done; \
	exit $$status

# TA only: records the current app's orders as the expected output for every
# fixture. Students should never need this.
update-expected: $(BUILD)/market_maker
	@for f in $(wildcard sim/fixtures/*.scn); do \
		name=$$(basename $$f .scn); \
		./$(BUILD)/market_maker $$f --out $(BUILD)/verify/$$name > /dev/null && \
		cp $(BUILD)/verify/$$name/orders.txt sim/fixtures/$$name.expected && \
		echo "recorded $$name"; \
	done

# ---------------------------------------------------------------------------
# Hole unit tests: tests/<module>_test.cpp drives one Verilated module, for
# the four modules you implement from scratch. Fast, isolated feedback before
# running make verify end to end.
# ---------------------------------------------------------------------------

# $(call hole_test,<module>,<rtl sources>): builds tests/<module>_test.cpp
# against the Verilated <module> as $(BUILD)/holes/<module>_test/<module>_test.
define hole_test
$(BUILD)/holes/$(1)_test/$(1)_test: $(2) tests/$(1)_test.cpp
	$$(REQUIRE_TOOLS)
	@mkdir -p $(BUILD)/holes
	verilator $$(VERILATOR_FLAGS) --top-module $(1) -Mdir $(BUILD)/holes/$(1)_test \
		-o $(1)_test $(2) $(abspath tests)/$(1)_test.cpp > /dev/null
HOLE_TESTS += $(BUILD)/holes/$(1)_test/$(1)_test
endef

$(eval $(call hole_test,market_data_parser,rtl/messages_pkg.sv rtl/market_data_parser.sv))
$(eval $(call hole_test,order_encoder,rtl/messages_pkg.sv rtl/order_encoder.sv))
$(eval $(call hole_test,sequence_check,rtl/messages_pkg.sv rtl/pipeline_pkg.sv rtl/sequence_check.sv))
$(eval $(call hole_test,book,rtl/messages_pkg.sv rtl/pipeline_pkg.sv rtl/book.sv))

test-holes: $(HOLE_TESTS)
	@status=0; for t in $(HOLE_TESTS); do ./$$t || status=1; done; exit $$status

# ---------------------------------------------------------------------------
# Timing: synthesis (Yosys) and place and route (nextpnr) for the ECP5
# LFE5U-85F, speed grade 6, in its CABGA381 package (as on the ULX3S board).
# The whole design and each module are placed on their own, with every input
# registered (see timing/wrappers.sv), in parallel. The placer aims for
# TIMING_GOAL_MHZ; the report shows what it achieved, met or not. Results are
# kept until an RTL file changes.
# ---------------------------------------------------------------------------

TIMING_DIR      := $(BUILD)/timing
TIMING_GOAL_MHZ := 100
TIMING_JOBS     ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# The whole design first, then each module in pipeline order.
TIMING_MODULES := market_data_parser sequence_check report_parser merge order_table book \
	pricing quote_manager order_encoder register_bank
TIMING_LOGS    := $(foreach design,market_maker $(TIMING_MODULES),$(TIMING_DIR)/$(design)/pnr.log)

# Keep the synthesized netlists (make would otherwise delete them as
# intermediate files, and redo synthesis every time).
.PRECIOUS: $(TIMING_DIR)/%/synthesized.json

$(TIMING_DIR)/%/synthesized.json: $(RTL_SOURCES) timing/wrappers.sv
	$(REQUIRE_TOOLS)
	@mkdir -p $(@D)
	@yosys -m slang -q -l $(@D)/synthesis.log \
		-p "read_slang $(RTL_SOURCES) timing/wrappers.sv --top $*_timing; \
		    synth_ecp5 -top $*_timing -json $@" > /dev/null \
		|| { echo "error: synthesis of $* failed (log: $(@D)/synthesis.log)" >&2; exit 1; }

$(TIMING_DIR)/%/pnr.log: $(TIMING_DIR)/%/synthesized.json
	@nextpnr-ecp5 --85k --package CABGA381 --speed 6 --out-of-context \
		--freq $(TIMING_GOAL_MHZ) --timing-allow-fail --json $< > $@ 2>&1 \
		|| { mv $@ $@.failed; echo "error: place and route of $* failed (log: $@.failed)" >&2; exit 1; }
	@echo "  done: $*"

timing:
	@if ! $(MAKE) --no-print-directory -q $(TIMING_LOGS) > /dev/null 2>&1; then \
		echo "Synthesizing, placing and routing the design and each module, $(TIMING_JOBS) at a time (a few minutes)..."; \
	fi
	@$(MAKE) --no-print-directory -j $(TIMING_JOBS) timing-logs
	@sh timing/report.sh $(TIMING_DIR) $(TIMING_MODULES)

timing-logs: $(TIMING_LOGS)
	@:


clean:
	rm -rf $(BUILD)
