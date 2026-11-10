// This file was generated with the help of Claude Code.

#include "app/market_maker.h"

#include "sim/messages/order_entry.h"

namespace app {

void MarketMaker::OnMarketData(std::span<const std::byte> bytes) {
    Send(fpga_.MarketData(bytes));
}

void MarketMaker::OnExecutionReport(std::span<const std::byte> bytes) {
    Send(fpga_.Report(bytes));
}

void MarketMaker::OnTimer(sim::Timestamp) {
    // Sample the mid; an invalid book keeps the last sample.
    const std::uint64_t mid = fpga_.ReadRegister(kRegisterMid);
    if (mid & kMidValid) {
        sampled_mid_ = static_cast<sim::Price>(mid & 0xFFFF'FFFFu);
        volatility_.Update(static_cast<double>(sampled_mid_));
    }

    const sim::Price credit = CalcCredit(volatility_.Variance(), sampled_mid_);
    if (credit != credit_) {
        Send(fpga_.WriteRegister(kRegisterCredit, static_cast<std::uint64_t>(credit)));
        credit_ = credit;
    }

    // Loss limit: marked to the sampled mid. Skipped until there is a mark.
    if (sampled_mid_ != 0 && !halted_) {
        const auto position = static_cast<std::int64_t>(fpga_.ReadRegister(kRegisterPosition));
        const auto cash = static_cast<std::int64_t>(fpga_.ReadRegister(kRegisterCash));
        if (cash + position * sampled_mid_ < -kLossLimit) {
            Send(fpga_.WriteRegister(kRegisterHalt, 1));  // the cancels come out here
            halted_ = true;
        }
    }
}

void MarketMaker::Send(const std::vector<FpgaOrder>& orders) {
    for (const FpgaOrder& order : orders) {
        const auto bytes = order.packet.view();
        switch (static_cast<sim::oe::InboundType>(sim::MessageTypeOf(bytes))) {
            case sim::oe::InboundType::EnterOrder:
                session_.Send(sim::Decode<sim::oe::EnterOrder>(bytes));
                break;
            case sim::oe::InboundType::ReplaceOrder:
                session_.Send(sim::Decode<sim::oe::ReplaceOrder>(bytes));
                break;
            case sim::oe::InboundType::CancelOrder:
                session_.Send(sim::Decode<sim::oe::CancelOrder>(bytes));
                break;
        }
        latencies_.push_back(order.latency_cycles);
    }
}

}  // namespace app
