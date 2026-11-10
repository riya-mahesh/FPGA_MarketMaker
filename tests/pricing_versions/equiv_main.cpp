// Random-input comparison of a pricing version against the original.
//   equiv every-cycle|between-items [cycles]
// every-cycle: credit changes each cycle. between-items: only while the
// pipeline is empty, as in the real system. Inputs include crossed books,
// too-wide spreads, off-grid prices, zero/huge sizes and huge credits.
// Exits 0 if no differences.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>

#include "Vpricing_equiv.h"
#include "verilated.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s every-cycle|between-items [cycles]\n", argv[0]);
        return 2;
    }
    const std::string mode = argv[1];
    const bool every_cycle = mode == "every-cycle";
    if (!every_cycle && mode != "between-items") {
        std::fprintf(stderr, "unknown credit mode: %s\n", mode.c_str());
        return 2;
    }
    const std::uint64_t cycles = argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 2'000'000;

    Vpricing_equiv d;
    std::mt19937_64 rng(12345);
    auto r = [&](std::uint64_t n) { return rng() % n; };
    auto tick = [&] { d.clk = 0; d.eval(); d.clk = 1; d.eval(); };
    auto random_credit = [&]() -> std::uint32_t {
        return r(10) == 0 ? static_cast<std::uint32_t>(rng()) : static_cast<std::uint32_t>(100 * r(40));
    };
    auto random_size = [&]() -> std::uint32_t {
        switch (r(6)) {
            case 0: return 0;
            case 1: return static_cast<std::uint32_t>(rng());
            default: return static_cast<std::uint32_t>(1 + r(2000));
        }
    };

    d.rst = 1;
    tick();
    d.rst = 0;

    std::uint64_t checked = 0, quoted = 0, mismatches = 0;
    for (std::uint64_t c = 0; c < cycles; ++c) {
        if (every_cycle) {
            d.in_valid = r(10) != 0;
            d.credit = random_credit();
        } else {
            const bool gap = (c % 12) >= 9;  // 3 idle cycles in every 12
            d.in_valid = !gap && r(10) != 0;
            if (c % 12 == 11) d.credit = random_credit();
        }
        const std::uint32_t bid = static_cast<std::uint32_t>(100 * r(3000));
        const std::int64_t spread_ticks = static_cast<std::int64_t>(r(22)) - 2;  // crossed .. too wide
        const std::uint32_t off_grid = r(20) == 0 ? static_cast<std::uint32_t>(r(100)) : 0;
        d.bid_price = bid;
        d.ask_price = bid + static_cast<std::uint32_t>(100 * spread_ticks) + off_grid;
        d.bid_size = random_size();
        d.ask_size = random_size();
        d.book_invalid = r(8) == 0;
        tick();

        if (d.mismatch && ++mismatches <= 3) {
            std::printf("  mismatch at cycle %llu: version bid %u ask %u, original bid %u ask %u\n",
                        static_cast<unsigned long long>(c), d.new_bid, d.new_ask, d.ref_bid, d.ref_ask);
        }
        if (d.both_valid) {
            ++checked;
            quoted += d.can_quote;
        }
    }
    std::printf("  credit %s: %llu items compared (%llu quoted), %llu mismatches\n", mode.c_str(),
                static_cast<unsigned long long>(checked), static_cast<unsigned long long>(quoted),
                static_cast<unsigned long long>(mismatches));
    return mismatches == 0 ? 0 : 1;
}
