// This file was generated with the help of Claude Code.
//
// Volatility and credit: the part of pricing that runs on the CPU, once per
// timer tick. Floating point is fine here; the FPGA never sees it.
#pragma once

#include <algorithm>
#include <cmath>

#include "app/config.h"
#include "sim/messages/types.h"

namespace app {

// EWMA estimate of the variance of log returns between timer samples.
class VolatilityEstimator {
public:
    void Update(double new_mid) {
        if (last_mid_ > 0.0) {
            const double log_return = std::log(new_mid / last_mid_);
            variance_ = kVolatilityDecay * variance_ +
                        (1.0 - kVolatilityDecay) * log_return * log_return;
        }
        last_mid_ = new_mid;
    }
    double Variance() const { return variance_; }

private:
    double variance_ = 0.0;
    double last_mid_ = 0.0;
};

// Half-spread in Price units, rounded up to a whole number of ticks (the FPGA
// adds it to prices already on the tick grid, so it must be on the grid too).
inline sim::Price CalcCredit(double variance, sim::Price mid) {
    const double credit = kCreditK * std::sqrt(variance) * static_cast<double>(mid);
    const auto ticks = static_cast<sim::Price>(std::ceil(credit / sim::kTickSize));
    return std::max(kMinCredit, ticks * sim::kTickSize);
}

}  // namespace app
