// This file was generated with the help of Claude Code.
//
// Unit tests for codebase/rtl/sequence_check.sv. Events arrive back to back
// (one per cycle) so that several are in the pipeline at once: the gap flag
// must be attached to exactly the events at and after the gap, never to the
// ones before it.

#include <cstdint>
#include <cstdio>
#include <optional>
#include <vector>

#include "Vsequence_check.h"
#include "verilated.h"

namespace {

int g_failures = 0;

#define CHECK_EQ(a, b)                                                                    \
    do {                                                                                  \
        const auto va = (a);                                                              \
        const auto vb = (b);                                                              \
        if (!(va == vb)) {                                                                \
            ++g_failures;                                                                 \
            std::fprintf(stderr, "  %s:%d: CHECK_EQ(%s, %s) got %llu vs %llu\n", __FILE__, \
                         __LINE__, #a, #b, static_cast<unsigned long long>(va),            \
                         static_cast<unsigned long long>(vb));                            \
        }                                                                                 \
    } while (0)

// Bit offsets within market_data_event_t (a packed struct puts its first
// field in the most significant bits).
constexpr int kEventSequenceLsb = 225;
constexpr int kEventOrderRefLsb = 161;

// pipeline_item_t is {level_updates, source, report_event, market_event,
// errors}: errors (4 bits: {book_overflow, unknown_order, sequence_gap,
// book_invalid}) are the low bits, the market event sits above them, and the
// source tag is above both events (0 = market data).
constexpr int kItemEventLsb = 4;
constexpr int kItemSequenceGapBit = 1;
constexpr int kItemBookInvalidBit = 0;
constexpr int kItemSourceBit = 588;

template <std::size_t N>
std::uint64_t Bits(const VlWide<N>& wide, int lsb, int width) {
    std::uint64_t value = 0;
    for (int i = 0; i < width; ++i) {
        const int bit = lsb + i;
        value |= static_cast<std::uint64_t>((wide[bit / 32] >> (bit % 32)) & 1u) << i;
    }
    return value;
}

template <std::size_t N>
void SetBits(VlWide<N>& wide, int lsb, int width, std::uint64_t value) {
    for (int i = 0; i < width; ++i) {
        const int bit = lsb + i;
        const std::uint32_t mask = 1u << (bit % 32);
        if ((value >> i) & 1u) {
            wide[bit / 32] |= mask;
        } else {
            wide[bit / 32] &= ~mask;
        }
    }
}

// An input event: its sequence number, plus an order ref used as a tag to
// check that each event comes out unchanged and in order.
struct Input {
    std::uint64_t sequence_number;
    std::uint64_t tag;
};

struct Output {
    std::uint64_t sequence_number;
    std::uint64_t tag;
    std::uint64_t sequence_gap;
    std::uint64_t book_invalid;
    std::uint64_t source;
};

class Harness {
public:
    Harness() { Reset(); }

    // Presents one event (or nothing) for one cycle, then returns the item the
    // stage produced on that clock edge, if any.
    std::optional<Output> Cycle(std::optional<Input> input) {
        dut_.market_event_valid = input.has_value();
        // When nothing is valid, leave a misleading sequence number on the bus:
        // it must be ignored.
        SetBits(dut_.market_event, kEventSequenceLsb, 64, input ? input->sequence_number : 999);
        SetBits(dut_.market_event, kEventOrderRefLsb, 64, input ? input->tag : 0);
        Tick();
        if (!dut_.item_valid) return std::nullopt;
        return Output{
            .sequence_number = Bits(dut_.item, kItemEventLsb + kEventSequenceLsb, 64),
            .tag = Bits(dut_.item, kItemEventLsb + kEventOrderRefLsb, 64),
            .sequence_gap = Bits(dut_.item, kItemSequenceGapBit, 1),
            .book_invalid = Bits(dut_.item, kItemBookInvalidBit, 1),
            .source = Bits(dut_.item, kItemSourceBit, 1),
        };
    }

    void Reset() {
        dut_.rst = 1;
        dut_.market_event_valid = 0;
        Tick();
        dut_.rst = 0;
    }

private:
    void Tick() {
        dut_.clk = 0;
        dut_.eval();
        dut_.clk = 1;
        dut_.eval();
    }

    Vsequence_check dut_;
};

// Feeds the given sequence numbers back to back and checks each item's gap
// flag against `expected_gap`. Each event is tagged with 100 + its position.
void Run(Harness& h, const std::vector<std::uint64_t>& sequence_numbers,
         const std::vector<std::uint64_t>& expected_gap) {
    for (std::size_t i = 0; i < sequence_numbers.size(); ++i) {
        const auto out = h.Cycle(Input{sequence_numbers[i], 100 + i});
        CHECK_EQ(out.has_value(), true);
        if (!out) continue;
        CHECK_EQ(out->sequence_number, sequence_numbers[i]);
        CHECK_EQ(out->tag, 100 + i);
        CHECK_EQ(out->sequence_gap, expected_gap[i]);
        CHECK_EQ(out->book_invalid, 0u);
        CHECK_EQ(out->source, 0u);  // tagged as market data
    }
}

void InOrderMessagesHaveNoGap() {
    Harness h;
    Run(h, {1, 2, 3, 4, 5}, {0, 0, 0, 0, 0});
}

void GapFlagsTheGapMessageAndEverythingAfter() {
    Harness h;
    // 4 is missing. 5 reveals the gap; 6 is in order after 5, but the flag
    // stays set. Messages before the gap must not be flagged.
    Run(h, {1, 2, 3, 5, 6, 7}, {0, 0, 0, 1, 1, 1});
}

void FirstMessageMustBeOne() {
    Harness h;
    Run(h, {2, 3}, {1, 1});
}

void RepeatedMessageIsAGap() {
    Harness h;
    Run(h, {1, 2, 2, 3}, {0, 0, 1, 1});
}

void IdleCyclesDoNotCount() {
    Harness h;
    // Between messages the bus carries junk (sequence 999) with valid low:
    // it must neither raise the flag nor move the expected number.
    CHECK_EQ(h.Cycle(Input{1, 0}).has_value(), true);
    CHECK_EQ(h.Cycle(std::nullopt).has_value(), false);
    CHECK_EQ(h.Cycle(std::nullopt).has_value(), false);
    const auto out = h.Cycle(Input{2, 0});
    CHECK_EQ(out.has_value(), true);
    if (out) CHECK_EQ(out->sequence_gap, 0u);
}

void FlagStaysSetAcrossIdleCycles() {
    Harness h;
    Run(h, {1, 3}, {0, 1});
    CHECK_EQ(h.Cycle(std::nullopt).has_value(), false);
    CHECK_EQ(h.Cycle(std::nullopt).has_value(), false);
    const auto out = h.Cycle(Input{4, 0});
    CHECK_EQ(out.has_value(), true);
    if (out) CHECK_EQ(out->sequence_gap, 1u);
}

void ItemIsValidOnlyForOneCycle() {
    Harness h;
    CHECK_EQ(h.Cycle(std::nullopt).has_value(), false);
    CHECK_EQ(h.Cycle(Input{1, 0}).has_value(), true);  // registered: valid on this edge
    CHECK_EQ(h.Cycle(std::nullopt).has_value(), false);
}

void ResetClearsTheFlagAndRestartsAtOne() {
    Harness h;
    Run(h, {1, 3}, {0, 1});
    h.Reset();
    Run(h, {1, 2}, {0, 0});
}

struct TestCase {
    const char* name;
    void (*fn)();
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const TestCase tests[] = {
        {"InOrderMessagesHaveNoGap", InOrderMessagesHaveNoGap},
        {"GapFlagsTheGapMessageAndEverythingAfter", GapFlagsTheGapMessageAndEverythingAfter},
        {"FirstMessageMustBeOne", FirstMessageMustBeOne},
        {"RepeatedMessageIsAGap", RepeatedMessageIsAGap},
        {"IdleCyclesDoNotCount", IdleCyclesDoNotCount},
        {"FlagStaysSetAcrossIdleCycles", FlagStaysSetAcrossIdleCycles},
        {"ItemIsValidOnlyForOneCycle", ItemIsValidOnlyForOneCycle},
        {"ResetClearsTheFlagAndRestartsAtOne", ResetClearsTheFlagAndRestartsAtOne},
    };
    for (const TestCase& test : tests) {
        const int before = g_failures;
        test.fn();
        std::printf("%s sequence_check: %s\n", g_failures == before ? "PASS" : "FAIL", test.name);
    }
    return g_failures == 0 ? 0 : 1;
}
