// This file was generated with the help of Claude Code.
//
// Unit tests for codebase/rtl/market_data_parser.sv. Messages are built with the simulator's
// own wire structs (sim/messages/market_data.h), so the parser is checked
// against the same layouts the exchange produces.

#include <cstdint>
#include <cstdio>
#include <optional>
#include <vector>

#include "Vmarket_data_parser.h"
#include "sim/messages/market_data.h"
#include "sim/messages/wire.h"
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

// market_data_kind_e values, in declaration order.
enum Kind : std::uint64_t { kAdd, kExecuted, kCancel, kDelete, kReplace };

// A decoded market_data_event_t. A packed struct puts its first field in the most
// significant bits, so the fields sit at these offsets from bit 0.
struct Event {
    std::uint64_t kind, sequence_number, order_ref, new_order_ref, is_buy, shares, price;
};

// in_data is MESSAGE_BITS = 512 bits, stored by Verilator as 32-bit words.
constexpr int kInWords = 512 / 32;

template <std::size_t N>
std::uint64_t Bits(const VlWide<N>& wide, int lsb, int width) {
    std::uint64_t value = 0;
    for (int i = 0; i < width; ++i) {
        const int bit = lsb + i;
        value |= static_cast<std::uint64_t>((wide[bit / 32] >> (bit % 32)) & 1u) << i;
    }
    return value;
}

class Harness {
public:
    Harness() {
        dut_.rst = 1;
        dut_.in_valid = 0;
        Tick();
        dut_.rst = 0;
    }

    // Presents one message (or nothing) for one cycle, then returns the event
    // the parser produced on that clock edge, if any.
    std::optional<Event> Cycle(const sim::Packet* packet) {
        dut_.in_valid = packet != nullptr;
        for (int w = 0; w < kInWords; ++w) dut_.in_data[w] = 0;
        if (packet != nullptr) {
            const auto bytes = packet->view();
            for (std::size_t i = 0; i < bytes.size(); ++i) {
                dut_.in_data[i / 4] |= static_cast<std::uint32_t>(bytes[i]) << (8 * (i % 4));
            }
        }
        Tick();
        if (!dut_.market_event_valid) return std::nullopt;
        return Event{
            .kind = Bits(dut_.market_event, 289, 3),
            .sequence_number = Bits(dut_.market_event, 225, 64),
            .order_ref = Bits(dut_.market_event, 161, 64),
            .new_order_ref = Bits(dut_.market_event, 97, 64),
            .is_buy = Bits(dut_.market_event, 96, 1),
            .shares = Bits(dut_.market_event, 64, 32),
            .price = Bits(dut_.market_event, 0, 64),
        };
    }

    void Reset() {
        dut_.rst = 1;
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

    Vmarket_data_parser dut_;
};

// Values with bits set in every byte, so a misplaced slice shows up.
constexpr std::uint64_t kSequenceNumber = 0x0102030405060708ull;
constexpr std::uint64_t kOrderRef = 0x1122334455667788ull;
constexpr std::uint64_t kNewOrderRef = 0x8877665544332211ull;
constexpr std::uint32_t kShares = 0xA1B2C3D4u;
constexpr std::int64_t kPrice = 0x0FEDCBA987654321ll;

template <typename Msg>
sim::Packet Make(sim::md::MsgType type, Msg msg) {
    msg.header.type = type;
    msg.header.instrument = sim::kInstrument;
    msg.header.sequence = kSequenceNumber;
    msg.header.timestamp = 0xFFFFFFFFFFFFFFFFull;  // not decoded; must not leak into fields
    return sim::Encode(msg);
}

sim::Packet Add(sim::Side side) {
    sim::md::AddOrder m{};
    m.order_ref = kOrderRef;
    m.side = side;
    m.shares = kShares;
    m.price = kPrice;
    return Make(sim::md::MsgType::AddOrder, m);
}

sim::Packet Executed() {
    sim::md::OrderExecuted m{};
    m.order_ref = kOrderRef;
    m.executed_shares = kShares;
    m.match_number = 0xFFFFFFFFFFFFFFFFull;  // not decoded
    return Make(sim::md::MsgType::OrderExecuted, m);
}

sim::Packet Cancel() {
    sim::md::OrderCancel m{};
    m.order_ref = kOrderRef;
    m.canceled_shares = kShares;
    return Make(sim::md::MsgType::OrderCancel, m);
}

sim::Packet Delete() {
    sim::md::OrderDelete m{};
    m.order_ref = kOrderRef;
    return Make(sim::md::MsgType::OrderDelete, m);
}

sim::Packet Replace() {
    sim::md::OrderReplace m{};
    m.original_order_ref = kOrderRef;
    m.new_order_ref = kNewOrderRef;
    m.shares = kShares;
    m.price = kPrice;
    return Make(sim::md::MsgType::OrderReplace, m);
}

// Fields a message doesn't carry must be zero.
void CheckEvent(const Event& e, Kind kind, std::uint64_t new_order_ref, std::uint64_t is_buy,
                std::uint64_t shares, std::uint64_t price) {
    CHECK_EQ(e.kind, kind);
    CHECK_EQ(e.sequence_number, kSequenceNumber);
    CHECK_EQ(e.order_ref, kOrderRef);
    CHECK_EQ(e.new_order_ref, new_order_ref);
    CHECK_EQ(e.is_buy, is_buy);
    CHECK_EQ(e.shares, shares);
    CHECK_EQ(e.price, price);
}

void DecodesEachMessageType() {
    Harness h;
    const auto price = static_cast<std::uint64_t>(kPrice);

    const sim::Packet add = Add(sim::Side::Buy);
    auto e = h.Cycle(&add);
    CHECK_EQ(e.has_value(), true);
    if (e) CheckEvent(*e, kAdd, 0, 1, kShares, price);

    const sim::Packet sell = Add(sim::Side::Sell);
    e = h.Cycle(&sell);
    CHECK_EQ(e.has_value(), true);
    if (e) CheckEvent(*e, kAdd, 0, 0, kShares, price);

    const sim::Packet executed = Executed();
    e = h.Cycle(&executed);
    CHECK_EQ(e.has_value(), true);
    if (e) CheckEvent(*e, kExecuted, 0, 0, kShares, 0);

    const sim::Packet cancel = Cancel();
    e = h.Cycle(&cancel);
    CHECK_EQ(e.has_value(), true);
    if (e) CheckEvent(*e, kCancel, 0, 0, kShares, 0);

    const sim::Packet del = Delete();
    e = h.Cycle(&del);
    CHECK_EQ(e.has_value(), true);
    if (e) CheckEvent(*e, kDelete, 0, 0, 0, 0);

    const sim::Packet replace = Replace();
    e = h.Cycle(&replace);
    CHECK_EQ(e.has_value(), true);
    if (e) CheckEvent(*e, kReplace, kNewOrderRef, 0, kShares, price);
}

void EventIsValidOnlyForOneCycle() {
    Harness h;
    const sim::Packet add = Add(sim::Side::Buy);
    CHECK_EQ(h.Cycle(nullptr).has_value(), false);
    CHECK_EQ(h.Cycle(&add).has_value(), true);    // registered: valid on this edge
    CHECK_EQ(h.Cycle(nullptr).has_value(), false); // and only this one
    CHECK_EQ(h.Cycle(nullptr).has_value(), false);
}

void AcceptsAMessageEveryCycle() {
    Harness h;
    const std::vector<sim::Packet> packets = {Add(sim::Side::Buy), Executed(), Cancel(),
                                              Delete(), Replace()};
    const Kind expected[] = {kAdd, kExecuted, kCancel, kDelete, kReplace};
    for (std::size_t i = 0; i < packets.size(); ++i) {
        const auto e = h.Cycle(&packets[i]);
        CHECK_EQ(e.has_value(), true);
        if (e) CHECK_EQ(e->kind, expected[i]);
    }
}

void IgnoresUnknownTypes() {
    Harness h;
    sim::Packet unknown = Delete();
    unknown.data[0] = std::byte{'Z'};
    CHECK_EQ(h.Cycle(&unknown).has_value(), false);
    const sim::Packet del = Delete();
    CHECK_EQ(h.Cycle(&del).has_value(), true);  // and keeps working afterwards
}

void ResetClearsValid() {
    Harness h;
    const sim::Packet add = Add(sim::Side::Buy);
    CHECK_EQ(h.Cycle(&add).has_value(), true);
    h.Reset();
    CHECK_EQ(h.Cycle(nullptr).has_value(), false);
}

struct TestCase {
    const char* name;
    void (*fn)();
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const TestCase tests[] = {
        {"DecodesEachMessageType", DecodesEachMessageType},
        {"EventIsValidOnlyForOneCycle", EventIsValidOnlyForOneCycle},
        {"AcceptsAMessageEveryCycle", AcceptsAMessageEveryCycle},
        {"IgnoresUnknownTypes", IgnoresUnknownTypes},
        {"ResetClearsValid", ResetClearsValid},
    };
    for (const TestCase& test : tests) {
        const int before = g_failures;
        test.fn();
        std::printf("%s market_data_parser: %s\n", g_failures == before ? "PASS" : "FAIL", test.name);
    }
    return g_failures == 0 ? 0 : 1;
}
