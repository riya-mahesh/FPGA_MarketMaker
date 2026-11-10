// This file was generated with the help of Claude Code.
//
// Unit tests for codebase/rtl/order_encoder.sv. Each encoded message is compared byte
// for byte (including the zero padding) against the simulator's own encoding
// of the same order (sim/messages/order_entry.h), so anything the encoder
// produces is exactly what the exchange expects.

#include <array>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <vector>

#include "Vorder_encoder.h"
#include "sim/messages/order_entry.h"
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

// order_kind_e values, in declaration order. kUnused is the fourth value of
// the 2-bit field, which the encoder must ignore.
enum Kind : std::uint64_t { kEnter, kReplace, kCancel, kUnused };

// An order_request_t. A packed struct puts its first field in the most
// significant bits, so the fields sit at these offsets from bit 0.
struct Request {
    std::uint64_t kind = 0, token = 0, existing_token = 0, is_buy = 0, shares = 0, price = 0;
};

constexpr int kMessageBytes = 512 / 8;  // MESSAGE_BITS
using Message = std::array<std::uint8_t, kMessageBytes>;

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

class Harness {
public:
    Harness() {
        dut_.rst = 1;
        dut_.request_valid = 0;
        Tick();
        dut_.rst = 0;
    }

    // Presents one request (or nothing) for one cycle, then returns the
    // message the encoder produced on that clock edge, if any.
    std::optional<Message> Cycle(const Request* request) {
        dut_.request_valid = request != nullptr;
        if (request != nullptr) {
            SetBits(dut_.request, 225, 2, request->kind);
            SetBits(dut_.request, 161, 64, request->token);
            SetBits(dut_.request, 97, 64, request->existing_token);
            SetBits(dut_.request, 96, 1, request->is_buy);
            SetBits(dut_.request, 64, 32, request->shares);
            SetBits(dut_.request, 0, 64, request->price);
        }
        Tick();
        if (!dut_.order_valid) return std::nullopt;
        Message message{};
        for (int i = 0; i < kMessageBytes; ++i) {
            message[i] = static_cast<std::uint8_t>(dut_.order_data[i / 4] >> (8 * (i % 4)));
        }
        return message;
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

    Vorder_encoder dut_;
};

// The simulator's encoding, padded with zeros to the bus width.
Message Expected(const sim::Packet& packet) {
    Message message{};
    const auto bytes = packet.view();
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        message[i] = static_cast<std::uint8_t>(bytes[i]);
    }
    return message;
}

void CheckMessage(const std::optional<Message>& actual, const sim::Packet& expected_packet) {
    CHECK_EQ(actual.has_value(), true);
    if (!actual) return;
    const Message expected = Expected(expected_packet);
    for (int i = 0; i < kMessageBytes; ++i) {
        if ((*actual)[i] != expected[i]) {
            ++g_failures;
            std::fprintf(stderr, "  byte %d: got 0x%02x, expected 0x%02x\n", i, (*actual)[i],
                         expected[i]);
        }
    }
}

// Values with bits set in every byte, so a misplaced field shows up.
constexpr std::uint64_t kToken = 0x0102030405060708ull;
constexpr std::uint64_t kExistingToken = 0x8877665544332211ull;
constexpr std::uint32_t kShares = 0xA1B2C3D4u;
constexpr std::int64_t kPrice = 0x0FEDCBA987654321ll;

Request EnterRequest(bool is_buy) {
    return {.kind = kEnter, .token = kToken, .is_buy = is_buy, .shares = kShares,
            .price = static_cast<std::uint64_t>(kPrice)};
}

sim::Packet EnterPacket(sim::Side side) {
    sim::oe::EnterOrder m{};
    m.token = kToken;
    m.side = side;
    m.shares = kShares;
    m.instrument = sim::kInstrument;
    m.price = kPrice;
    m.time_in_force = sim::oe::TimeInForce::Day;
    return sim::Encode(m);
}

Request ReplaceRequest() {
    return {.kind = kReplace, .token = kToken, .existing_token = kExistingToken,
            .shares = kShares, .price = static_cast<std::uint64_t>(kPrice)};
}

sim::Packet ReplacePacket() {
    sim::oe::ReplaceOrder m{};
    m.existing_token = kExistingToken;
    m.replacement_token = kToken;
    m.shares = kShares;
    m.price = kPrice;
    return sim::Encode(m);
}

Request CancelRequest(std::uint32_t remaining) {
    return {.kind = kCancel, .token = kToken, .shares = remaining};
}

sim::Packet CancelPacket(std::uint32_t remaining) {
    sim::oe::CancelOrder m{};
    m.token = kToken;
    m.shares = remaining;
    return sim::Encode(m);
}

void EncodesEachRequestKind() {
    Harness h;
    const Request buy = EnterRequest(true);
    CheckMessage(h.Cycle(&buy), EnterPacket(sim::Side::Buy));
    const Request sell = EnterRequest(false);
    CheckMessage(h.Cycle(&sell), EnterPacket(sim::Side::Sell));
    const Request replace = ReplaceRequest();
    CheckMessage(h.Cycle(&replace), ReplacePacket());
    const Request cancel = CancelRequest(0);
    CheckMessage(h.Cycle(&cancel), CancelPacket(0));
    const Request reduce = CancelRequest(kShares);
    CheckMessage(h.Cycle(&reduce), CancelPacket(kShares));
}

void OrderIsValidOnlyForOneCycle() {
    Harness h;
    const Request buy = EnterRequest(true);
    CHECK_EQ(h.Cycle(nullptr).has_value(), false);
    CHECK_EQ(h.Cycle(&buy).has_value(), true);    // registered: valid on this edge
    CHECK_EQ(h.Cycle(nullptr).has_value(), false); // and only this one
    CHECK_EQ(h.Cycle(nullptr).has_value(), false);
}

void AcceptsARequestEveryCycle() {
    Harness h;
    const std::vector<Request> requests = {EnterRequest(true), ReplaceRequest(), CancelRequest(0)};
    const std::vector<sim::Packet> expected = {EnterPacket(sim::Side::Buy), ReplacePacket(),
                                               CancelPacket(0)};
    for (std::size_t i = 0; i < requests.size(); ++i) {
        CheckMessage(h.Cycle(&requests[i]), expected[i]);
    }
}

void IgnoresUnknownKind() {
    Harness h;
    Request unknown = EnterRequest(true);
    unknown.kind = kUnused;
    CHECK_EQ(h.Cycle(&unknown).has_value(), false);
    const Request cancel = CancelRequest(0);
    CheckMessage(h.Cycle(&cancel), CancelPacket(0));  // and keeps working afterwards
}

void ResetClearsValid() {
    Harness h;
    const Request buy = EnterRequest(true);
    CHECK_EQ(h.Cycle(&buy).has_value(), true);
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
        {"EncodesEachRequestKind", EncodesEachRequestKind},
        {"OrderIsValidOnlyForOneCycle", OrderIsValidOnlyForOneCycle},
        {"AcceptsARequestEveryCycle", AcceptsARequestEveryCycle},
        {"IgnoresUnknownKind", IgnoresUnknownKind},
        {"ResetClearsValid", ResetClearsValid},
    };
    for (const TestCase& test : tests) {
        const int before = g_failures;
        test.fn();
        std::printf("%s order_encoder: %s\n", g_failures == before ? "PASS" : "FAIL", test.name);
    }
    return g_failures == 0 ? 0 : 1;
}
