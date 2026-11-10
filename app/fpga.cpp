// This file was generated with the help of Claude Code.

#include "app/fpga.h"

#include <cstring>
#include <stdexcept>

#include "Vmarket_maker.h"
#include "sim/messages/order_entry.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

namespace app {

namespace {

constexpr int kMessageWords = sim::kMaxPacketSize / 4;  // 512 bits as 32-bit words

// Copies a message into a 512-bit port: byte 0 in bits [7:0], the rest zero.
void Load(VlWide<kMessageWords>& port, std::span<const std::byte> bytes) {
    if (bytes.size() > sim::kMaxPacketSize) {
        throw std::invalid_argument("Fpga: message longer than the 512-bit input");
    }
    for (int w = 0; w < kMessageWords; ++w) port[w] = 0;
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        port[i / 4] |= static_cast<std::uint32_t>(bytes[i]) << (8 * (i % 4));
    }
}

// Reads an order off the 512-bit output; its type byte gives its length.
sim::Packet Unload(const VlWide<kMessageWords>& port) {
    sim::Packet packet;
    for (std::size_t i = 0; i < sim::kMaxPacketSize; ++i) {
        packet.data[i] = static_cast<std::byte>(port[i / 4] >> (8 * (i % 4)));
    }
    switch (static_cast<sim::oe::InboundType>(packet.data[0])) {
        case sim::oe::InboundType::EnterOrder:
            packet.size = sizeof(sim::oe::EnterOrder);
            break;
        case sim::oe::InboundType::ReplaceOrder:
            packet.size = sizeof(sim::oe::ReplaceOrder);
            break;
        case sim::oe::InboundType::CancelOrder:
            packet.size = sizeof(sim::oe::CancelOrder);
            break;
        default:
            throw std::runtime_error("Fpga: the design sent an order of unknown type");
    }
    return packet;
}

}  // namespace

Fpga::Fpga() : design_(std::make_unique<Vmarket_maker>()) {
    design_->rst = 1;
    Tick();
    design_->rst = 0;
}

Fpga::~Fpga() {
    if (waves_) waves_->close();
}

void Fpga::OpenWaves(const std::string& path) {
    Verilated::traceEverOn(true);
    waves_ = std::make_unique<VerilatedVcdC>();
    design_->trace(waves_.get(), 99);  // every level of the hierarchy
    waves_->open(path.c_str());
}

std::vector<FpgaOrder> Fpga::MarketData(std::span<const std::byte> bytes) {
    Load(design_->market_data, bytes);
    design_->market_data_valid = 1;
    return RunUntilQuiet();
}

std::vector<FpgaOrder> Fpga::Report(std::span<const std::byte> bytes) {
    Load(design_->report, bytes);
    design_->report_valid = 1;
    return RunUntilQuiet();
}

std::vector<FpgaOrder> Fpga::WriteRegister(std::uint32_t address, std::uint64_t value) {
    design_->register_write_valid = 1;
    design_->register_write_address = address;
    design_->register_write_data = value;
    return RunUntilQuiet();
}

std::uint64_t Fpga::ReadRegister(std::uint32_t address) {
    design_->register_read_address = address;
    design_->eval();
    return design_->register_read_data;
}

// The first cycle carries whatever input was set up; the rest are idle.
std::vector<FpgaOrder> Fpga::RunUntilQuiet() {
    std::vector<FpgaOrder> orders;
    const std::uint64_t start = cycle_;
    for (int quiet = 0; quiet < kQuietCycles;) {
        Tick();
        design_->market_data_valid = 0;
        design_->report_valid = 0;
        design_->register_write_valid = 0;
        if (design_->overflow) {
            // Can't happen when messages arrive one at a time; if it does,
            // the design lost a message and nothing after can be trusted.
            throw std::runtime_error("Fpga: the design dropped a message (overflow)");
        }
        if (design_->order_valid) {
            orders.push_back({Unload(design_->order), cycle_ - start - 1});
            quiet = 0;
        } else {
            ++quiet;
        }
    }
    return orders;
}

void Fpga::Tick() {
    design_->clk = 0;
    design_->eval();
    if (waves_) waves_->dump(2 * cycle_);
    design_->clk = 1;
    design_->eval();
    if (waves_) waves_->dump(2 * cycle_ + 1);
    ++cycle_;
}

}  // namespace app
