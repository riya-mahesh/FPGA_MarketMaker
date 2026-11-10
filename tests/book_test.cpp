// This file was generated with the help of Claude Code.
//
// Unit tests for codebase/rtl/book.sv. Only the top of book is visible, so
// sorted order is checked by filling a side and removing the best level
// repeatedly: each new best must be the next price in order.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <optional>
#include <vector>

#include "Vbook.h"
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

// ---- Bit layout (a packed struct puts its first field in the top bits) ----

// errors: {book_overflow, unknown_order, sequence_gap, book_invalid}
constexpr int kBookInvalidBit = 0;
constexpr int kSequenceGapBit = 1;
constexpr int kBookOverflowBit = 3;

// Input, book_item_t: {level_updates[1:0], source, report_event, errors}
constexpr int kInReportLsb = 4;
constexpr int kInSourceBit = 296;
constexpr int kInUpdatesLsb = 297;  // level_updates[0]; [1] follows
constexpr int kUpdateBits = 67;     // level_update_t: {valid, is_buy, add, price, shares}

// Output, pricing_item_t: {top_of_book, source, report_event, errors}
constexpr int kOutReportLsb = 4;
constexpr int kOutSourceBit = 296;
constexpr int kOutTopLsb = 297;     // top_of_book_t: {bid_price, bid_size, ask_price, ask_size}

constexpr int kReportTokenLsb = 225;  // within report_event_t
constexpr int kLevels = 16;           // book's default LEVELS

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

// ---- Inputs and outputs ----

struct Update {
    bool is_buy;
    bool add;
    std::uint64_t price;
    std::uint64_t shares;
};

Update BidJoins(std::uint64_t price, std::uint64_t shares) { return {true, true, price, shares}; }
Update BidLeaves(std::uint64_t price, std::uint64_t shares) { return {true, false, price, shares}; }
Update AskJoins(std::uint64_t price, std::uint64_t shares) { return {false, true, price, shares}; }
Update AskLeaves(std::uint64_t price, std::uint64_t shares) { return {false, false, price, shares}; }

struct Output {
    std::uint64_t bid_price, bid_size, ask_price, ask_size;
    bool book_invalid;
    bool book_overflow;
    bool sequence_gap;
    bool is_report;
    std::uint64_t token;
};

class Harness {
public:
    Harness() { Reset(); }

    // Presents one item carrying up to two updates for one cycle, followed by
    // one idle cycle (items arrive at least two cycles apart), and returns what
    // the book produced after those two cycles.
    std::optional<Output> Cycle(const std::vector<Update>& updates, bool is_report = false,
                                std::uint64_t token = 0, bool sequence_gap = false) {
        Clear();
        dut_.in_item_valid = 1;
        auto& w = dut_.in_item;
        SetBits(w, kInSourceBit, 1, is_report);
        SetBits(w, kInReportLsb + kReportTokenLsb, 64, token);
        SetBits(w, kSequenceGapBit, 1, sequence_gap);
        for (std::size_t u = 0; u < updates.size(); ++u) {
            const int lsb = kInUpdatesLsb + static_cast<int>(u) * kUpdateBits;
            SetBits(w, lsb + 66, 1, 1);  // valid
            SetBits(w, lsb + 65, 1, updates[u].is_buy);
            SetBits(w, lsb + 64, 1, updates[u].add);
            SetBits(w, lsb + 32, 32, updates[u].price);
            SetBits(w, lsb + 0, 32, updates[u].shares);
        }
        Tick();
        dut_.in_item_valid = 0;
        Clear();
        Tick();
        if (!dut_.item_valid) return std::nullopt;
        const auto& o = dut_.item;
        return Output{
            .bid_price = Bits(o, kOutTopLsb + 96, 32),
            .bid_size = Bits(o, kOutTopLsb + 64, 32),
            .ask_price = Bits(o, kOutTopLsb + 32, 32),
            .ask_size = Bits(o, kOutTopLsb + 0, 32),
            .book_invalid = Bits(o, kBookInvalidBit, 1) != 0,
            .book_overflow = Bits(o, kBookOverflowBit, 1) != 0,
            .sequence_gap = Bits(o, kSequenceGapBit, 1) != 0,
            .is_report = Bits(o, kOutSourceBit, 1) != 0,
            .token = Bits(o, kOutReportLsb + kReportTokenLsb, 64),
        };
    }

    // One idle cycle; returns whether anything came out.
    bool Idle() {
        Clear();
        dut_.in_item_valid = 0;
        Tick();
        return dut_.item_valid;
    }

    void Reset() {
        dut_.rst = 1;
        dut_.in_item_valid = 0;
        Tick();
        dut_.rst = 0;
    }

private:
    void Clear() {
        for (auto i = 0u; i < sizeof(dut_.in_item) / sizeof(dut_.in_item[0]); ++i) {
            dut_.in_item[i] = 0;
        }
    }

    void Tick() {
        dut_.clk = 0;
        dut_.eval();
        dut_.clk = 1;
        dut_.eval();
    }

    Vbook dut_;
};

// Prices: 4 implied decimals, $0.01 ticks.
constexpr std::uint64_t Cents(std::uint64_t cents) { return cents * 100; }

// ---- Tests ----

void EmptyBookIsInvalid() {
    Harness h;
    const auto out = h.Cycle({});
    CHECK_EQ(out.has_value(), true);
    if (!out) return;
    CHECK_EQ(out->bid_size, 0u);
    CHECK_EQ(out->ask_size, 0u);
    CHECK_EQ(out->book_invalid, true);
    CHECK_EQ(out->book_overflow, false);
}

void BuildsBothSidesBestFirst() {
    Harness h;
    h.Cycle({BidJoins(Cents(9998), 100)});
    h.Cycle({BidJoins(Cents(10000), 200)});
    h.Cycle({BidJoins(Cents(9999), 300)});
    h.Cycle({AskJoins(Cents(10003), 400)});
    h.Cycle({AskJoins(Cents(10001), 500)});
    auto out = h.Cycle({AskJoins(Cents(10002), 600)});
    if (!out) { CHECK_EQ(out.has_value(), true); return; }
    CHECK_EQ(out->bid_price, Cents(10000));
    CHECK_EQ(out->bid_size, 200u);
    CHECK_EQ(out->ask_price, Cents(10001));
    CHECK_EQ(out->ask_size, 500u);
    CHECK_EQ(out->book_invalid, false);

    // Emptying the best level reveals the next one.
    out = h.Cycle({BidLeaves(Cents(10000), 200)});
    if (out) { CHECK_EQ(out->bid_price, Cents(9999)); CHECK_EQ(out->bid_size, 300u); }
    out = h.Cycle({AskLeaves(Cents(10001), 500)});
    if (out) { CHECK_EQ(out->ask_price, Cents(10002)); CHECK_EQ(out->ask_size, 600u); }
}

void SizesAddUpAtOnePrice() {
    Harness h;
    h.Cycle({AskJoins(Cents(10001), 100)});
    h.Cycle({BidJoins(Cents(10000), 100)});
    auto out = h.Cycle({BidJoins(Cents(10000), 250)});
    if (out) CHECK_EQ(out->bid_size, 350u);
    out = h.Cycle({BidLeaves(Cents(10000), 50)});  // partial: the level stays
    if (out) { CHECK_EQ(out->bid_price, Cents(10000)); CHECK_EQ(out->bid_size, 300u); }
}

// Fills one side with kLevels prices in a scrambled order, then removes the
// best level repeatedly: the prices must come out best first.
void CheckSideStaysSorted(bool is_buy) {
    Harness h;
    std::vector<std::uint64_t> prices;
    for (int i = 0; i < kLevels; ++i) prices.push_back(Cents(9900 + (i * 7) % kLevels));
    for (std::uint64_t p : prices) h.Cycle({{is_buy, true, p, p / 100}});
    if (is_buy) {
        std::sort(prices.begin(), prices.end(), std::greater<>());
    } else {
        std::sort(prices.begin(), prices.end());
    }
    for (std::uint64_t p : prices) {
        // Before removing it, this price must be the best.
        const auto out = h.Cycle({});
        if (!out) { CHECK_EQ(out.has_value(), true); return; }
        CHECK_EQ(is_buy ? out->bid_price : out->ask_price, p);
        CHECK_EQ(is_buy ? out->bid_size : out->ask_size, p / 100);
        h.Cycle({{is_buy, false, p, p / 100}});
    }
    const auto out = h.Cycle({});
    if (out) CHECK_EQ(is_buy ? out->bid_size : out->ask_size, 0u);
}

void BidsStaySorted() { CheckSideStaysSorted(true); }
void AsksStaySorted() { CheckSideStaysSorted(false); }

void ReplaceAppliesBothUpdatesInOneItem() {
    Harness h;
    h.Cycle({AskJoins(Cents(10005), 100)});
    h.Cycle({BidJoins(Cents(10000), 100)});
    // A replace: 100 leave 100.00, 100 join 100.02, in one item.
    const auto out = h.Cycle({BidLeaves(Cents(10000), 100), BidJoins(Cents(10002), 100)});
    if (!out) { CHECK_EQ(out.has_value(), true); return; }
    CHECK_EQ(out->bid_price, Cents(10002));
    CHECK_EQ(out->bid_size, 100u);
}

void TwoUpdatesAtTheSamePrice() {
    Harness h;
    h.Cycle({AskJoins(Cents(10005), 100)});
    h.Cycle({BidJoins(Cents(10000), 100)});
    // A replace that only changes size: 100 leave (emptying the level), 80
    // join at the same price.
    const auto out = h.Cycle({BidLeaves(Cents(10000), 100), BidJoins(Cents(10000), 80)});
    if (!out) { CHECK_EQ(out.has_value(), true); return; }
    CHECK_EQ(out->bid_price, Cents(10000));
    CHECK_EQ(out->bid_size, 80u);
}

void CrossedOrLockedBookIsInvalid() {
    Harness h;
    h.Cycle({BidJoins(Cents(10000), 100)});
    auto out = h.Cycle({AskJoins(Cents(10001), 100)});
    if (out) CHECK_EQ(out->book_invalid, false);
    out = h.Cycle({BidJoins(Cents(10001), 100)});  // locked: bid == ask
    if (out) CHECK_EQ(out->book_invalid, true);
    out = h.Cycle({BidJoins(Cents(10002), 100)});  // crossed: bid > ask
    if (out) CHECK_EQ(out->book_invalid, true);
    h.Cycle({BidLeaves(Cents(10002), 100)});
    out = h.Cycle({BidLeaves(Cents(10001), 100)});
    if (out) CHECK_EQ(out->book_invalid, false);  // per item, not sticky
}

void SixteenLevelsFit() {
    Harness h;
    std::optional<Output> out;
    for (int i = 0; i < kLevels; ++i) out = h.Cycle({BidJoins(Cents(10000 - i), 10)});
    if (out) CHECK_EQ(out->book_overflow, false);
}

void WorseSeventeenthLevelOverflows() {
    Harness h;
    for (int i = 0; i < kLevels; ++i) h.Cycle({BidJoins(Cents(10000 - i), 10)});
    auto out = h.Cycle({BidJoins(Cents(10000 - kLevels), 10)});  // worse than all 16
    if (out) CHECK_EQ(out->book_overflow, true);
    out = h.Cycle({});  // sticky
    if (out) CHECK_EQ(out->book_overflow, true);
}

void BetterSeventeenthLevelPushesTheWorstOut() {
    Harness h;
    for (int i = 0; i < kLevels; ++i) h.Cycle({AskJoins(Cents(10001 + i), 10)});
    const auto out = h.Cycle({AskJoins(Cents(10000), 99)});  // better than all 16
    if (!out) { CHECK_EQ(out.has_value(), true); return; }
    CHECK_EQ(out->ask_price, Cents(10000));
    CHECK_EQ(out->ask_size, 99u);
    CHECK_EQ(out->book_overflow, true);
}

void RemovingAnUntrackedLevelOverflows() {
    Harness h;
    h.Cycle({BidJoins(Cents(10000), 10)});
    const auto out = h.Cycle({BidLeaves(Cents(9990), 10)});
    if (out) CHECK_EQ(out->book_overflow, true);
}

void ReportsAndErrorsPassThrough() {
    Harness h;
    h.Cycle({AskJoins(Cents(10001), 100)});
    h.Cycle({BidJoins(Cents(10000), 100)});
    h.Cycle({BidJoins(Cents(9999), 100)});
    // A report that removes our own order's shares (the feed had added it).
    auto out = h.Cycle({BidLeaves(Cents(10000), 100)}, /*is_report=*/true, /*token=*/42);
    if (!out) { CHECK_EQ(out.has_value(), true); return; }
    CHECK_EQ(out->is_report, true);
    CHECK_EQ(out->token, 42u);
    CHECK_EQ(out->bid_price, Cents(9999));
    out = h.Cycle({}, false, 0, /*sequence_gap=*/true);
    if (out) { CHECK_EQ(out->sequence_gap, true); CHECK_EQ(out->is_report, false); }
}

void LatencyIsTwoCycles() {
    Harness h;
    CHECK_EQ(h.Idle(), false);
    // Cycle() presents the item, then waits one cycle: the item comes out on
    // that second clock edge, and only then.
    CHECK_EQ(h.Cycle({BidJoins(Cents(10000), 10)}).has_value(), true);
    CHECK_EQ(h.Idle(), false);
}

void ResetEmptiesTheBook() {
    Harness h;
    for (int i = 0; i <= kLevels; ++i) h.Cycle({BidJoins(Cents(10000 - i), 10)});  // overflow
    h.Reset();
    const auto out = h.Cycle({});
    if (!out) { CHECK_EQ(out.has_value(), true); return; }
    CHECK_EQ(out->bid_size, 0u);
    CHECK_EQ(out->book_overflow, false);
}

struct TestCase {
    const char* name;
    void (*fn)();
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const TestCase tests[] = {
        {"EmptyBookIsInvalid", EmptyBookIsInvalid},
        {"BuildsBothSidesBestFirst", BuildsBothSidesBestFirst},
        {"SizesAddUpAtOnePrice", SizesAddUpAtOnePrice},
        {"BidsStaySorted", BidsStaySorted},
        {"AsksStaySorted", AsksStaySorted},
        {"ReplaceAppliesBothUpdatesInOneItem", ReplaceAppliesBothUpdatesInOneItem},
        {"TwoUpdatesAtTheSamePrice", TwoUpdatesAtTheSamePrice},
        {"CrossedOrLockedBookIsInvalid", CrossedOrLockedBookIsInvalid},
        {"SixteenLevelsFit", SixteenLevelsFit},
        {"WorseSeventeenthLevelOverflows", WorseSeventeenthLevelOverflows},
        {"BetterSeventeenthLevelPushesTheWorstOut", BetterSeventeenthLevelPushesTheWorstOut},
        {"RemovingAnUntrackedLevelOverflows", RemovingAnUntrackedLevelOverflows},
        {"ReportsAndErrorsPassThrough", ReportsAndErrorsPassThrough},
        {"LatencyIsTwoCycles", LatencyIsTwoCycles},
        {"ResetEmptiesTheBook", ResetEmptiesTheBook},
    };
    for (const TestCase& test : tests) {
        const int before = g_failures;
        test.fn();
        std::printf("%s book: %s\n", g_failures == before ? "PASS" : "FAIL", test.name);
    }
    return g_failures == 0 ? 0 : 1;
}
