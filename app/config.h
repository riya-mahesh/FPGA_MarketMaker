// This file was generated with the help of Claude Code.
//
// Strategy parameters the CPU's cold path uses. These are part of the fixed
// behavior: changing any of them changes the order stream, and `make verify`
// will fail. (The parameters the FPGA uses, such as the quote size and the
// position limit, are in rtl/config_pkg.sv.)
#pragma once

#include <cstdint>

#include "sim/messages/types.h"

namespace app {

// Minimum half-spread, in Price units ($0.01). Must match MIN_CREDIT in
// rtl/config_pkg.sv, which is the credit register's value until the first
// write.
inline constexpr sim::Price kMinCredit = 100;

// Half-spread multiplier on volatility: credit = kCreditK * vol * mid.
inline constexpr double kCreditK = 2.0;

// Weight of the old variance in the volatility estimate, per timer tick.
inline constexpr double kVolatilityDecay = 0.94;

// Maximum loss before quoting stops, in Price units x shares ($100).
inline constexpr std::int64_t kLossLimit = 1'000'000;

}  // namespace app
