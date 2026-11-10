// This file was generated with the help of Claude Code.
//
// The FPGA board, simulated: the market_maker design (rtl/market_maker.sv),
// compiled to C++ by Verilator, with its clock driven from here.
//
// On a real board, messages arrive from the network while the clock runs on
// its own. Here the simulator hands us one message at a time, and simulated
// time stands still while we handle it, so each message is processed to
// completion before the next arrives:
//
//   1. the message is presented on its input for one cycle;
//   2. the clock runs until the design has been quiet (no order out) for
//      kQuietCycles cycles, longer than any message takes to get through;
//   3. the orders that came out are returned, in order.
//
// Latency is counted in clock cycles, from the cycle a message is presented
// to the cycle each order comes out. Multiply by the clock period your
// design meets (make timing) to get time.
//
// The register bus works the same way: a write takes one cycle, and the
// clock then runs until quiet, so the effect of a halt (the cancels) comes
// out of the write.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include "sim/messages/wire.h"

class Vmarket_maker;
class VerilatedVcdC;

namespace app {

// Register map (rtl/config_pkg.sv).
inline constexpr std::uint32_t kRegisterCredit = 0;
inline constexpr std::uint32_t kRegisterHalt = 1;
inline constexpr std::uint32_t kRegisterPosition = 2;
inline constexpr std::uint32_t kRegisterCash = 3;
inline constexpr std::uint32_t kRegisterMid = 4;  // kMidValid | (bid + ask) / 2
inline constexpr std::uint64_t kMidValid = 1ull << 63;

// One order the design sent.
struct FpgaOrder {
    sim::Packet packet;
    std::uint64_t latency_cycles;  // from the input that caused it
};

class Fpga {
public:
    Fpga();
    ~Fpga();
    Fpga(const Fpga&) = delete;
    Fpga& operator=(const Fpga&) = delete;

    // Records every signal, every cycle, to a VCD file for GTKWave. Slow and
    // large: use it on short scenarios.
    void OpenWaves(const std::string& path);

    // Each returns the orders the input caused.
    std::vector<FpgaOrder> MarketData(std::span<const std::byte> bytes);
    std::vector<FpgaOrder> Report(std::span<const std::byte> bytes);
    std::vector<FpgaOrder> WriteRegister(std::uint32_t address, std::uint64_t value);

    // Reads are combinational: no clock cycle passes.
    std::uint64_t ReadRegister(std::uint32_t address);

    std::uint64_t cycles() const { return cycle_; }

    // Longer than any message takes to get through the design.
    static constexpr int kQuietCycles = 64;

private:
    std::vector<FpgaOrder> RunUntilQuiet();
    void Tick();

    std::unique_ptr<Vmarket_maker> design_;
    std::unique_ptr<VerilatedVcdC> waves_;
    std::uint64_t cycle_ = 0;
};

}  // namespace app
