// This file was generated with the help of Claude Code.
//
// The market maker as the simulator sees it: an application whose hot path
// runs on the FPGA.
//
// Hot path: OnMarketData and OnExecutionReport hand each message to the
// board as is (the FPGA parses it) and send whatever orders come out. The
// CPU makes no decisions here.
//
// Cold path: OnTimer runs on the CPU. It samples the mid from the board,
// updates volatility and writes the credit it implies, and checks the loss
// limit against the board's position and cash, writing halt if breached.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#include "app/fpga.h"
#include "app/volatility.h"
#include "sim/runtime/simulator.h"

namespace app {

class MarketMaker {
public:
    MarketMaker(sim::OrderEntrySession& session, Fpga& fpga) : session_(session), fpga_(fpga) {}

    void OnMarketData(std::span<const std::byte> bytes);
    void OnExecutionReport(std::span<const std::byte> bytes);
    void OnTimer(sim::Timestamp now);

    // The latency of every order sent, in clock cycles.
    const std::vector<std::uint64_t>& latencies() const { return latencies_; }

private:
    void Send(const std::vector<FpgaOrder>& orders);

    sim::OrderEntrySession& session_;
    Fpga& fpga_;
    std::vector<std::uint64_t> latencies_;

    VolatilityEstimator volatility_;
    sim::Price sampled_mid_ = 0;     // mid at the last timer with a valid book; 0 = none yet
    sim::Price credit_ = kMinCredit;  // the credit register's current value
    bool halted_ = false;
};

}  // namespace app
