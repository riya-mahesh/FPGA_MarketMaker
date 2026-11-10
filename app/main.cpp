// This file was generated with the help of Claude Code.
//
// Runs the market maker on a scenario.
//
//   build/market_maker <scenario.scn> [--out <dir>] [--trace] [--waves]
//
// Writes into <dir> (default: build/out/<scenario name>):
//   orders.txt   every order sent: simulated time + message (used by make verify)
//   trace.txt    full human-readable message trace (only with --trace)
//   waves.vcd    every signal in the design, every cycle, for GTKWave (only
//                with --waves; slow and large, so use it on short scenarios)
// and prints the order latency, in clock cycles.

#include <algorithm>
#include <cstdint>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "app/fpga.h"
#include "app/market_maker.h"
#include "sim/messages/format.h"
#include "sim/runtime/capture.h"
#include "sim/runtime/simulator.h"

namespace {

void WriteOrders(const sim::Capture& capture, std::ostream& out) {
    for (const sim::SendRecord& s : capture.sends) {
        out << capture.deliveries[s.delivery_index].sim_time << ' '
            << sim::FormatInbound(s.packet.view()) << '\n';
    }
}

void PrintLatency(std::vector<std::uint64_t> latencies, std::uint64_t cycles, std::ostream& out) {
    out << "orders sent: " << latencies.size() << " (" << cycles << " cycles simulated)\n";
    if (latencies.empty()) return;
    std::sort(latencies.begin(), latencies.end());
    const auto at = [&](double q) {
        return latencies[static_cast<std::size_t>(q * (latencies.size() - 1))];
    };
    out << "latency, message in to order out, in clock cycles:\n"
        << "  min " << latencies.front() << "  median " << at(0.5) << "  p99 " << at(0.99)
        << "  max " << latencies.back() << '\n';
}

}  // namespace

int main(int argc, char** argv) {
    std::filesystem::path scenario_path;
    std::filesystem::path out_dir;
    bool trace = false;
    bool waves = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--out" && i + 1 < argc) {
            out_dir = argv[++i];
        } else if (arg == "--trace") {
            trace = true;
        } else if (arg == "--waves") {
            waves = true;
        } else if (scenario_path.empty() && !arg.starts_with("--")) {
            scenario_path = arg;
        } else {
            scenario_path.clear();
            break;
        }
    }
    if (scenario_path.empty()) {
        std::cerr << "usage: " << argv[0]
                  << " <scenario.scn> [--out <dir>] [--trace] [--waves]\n";
        return 2;
    }
    try {
        if (out_dir.empty()) {
            out_dir = std::filesystem::path("build/out") / scenario_path.stem();
        }
        std::filesystem::create_directories(out_dir);

        sim::Simulator simulator(sim::LoadScenario(scenario_path.string()));
        sim::Capture capture;
        simulator.set_capture(&capture);
        std::ofstream trace_file;
        if (trace) {
            trace_file.open(out_dir / "trace.txt");
            simulator.set_trace(&trace_file);
        }

        app::Fpga fpga;
        if (waves) fpga.OpenWaves((out_dir / "waves.vcd").string());
        app::MarketMaker market_maker(simulator.session(), fpga);
        simulator.Run(market_maker);

        std::ofstream orders(out_dir / "orders.txt");
        WriteOrders(capture, orders);
        PrintLatency(market_maker.latencies(), fpga.cycles(), std::cout);
    } catch (const std::exception& e) {
        std::cerr << "error: " << e.what() << '\n';
        return 1;
    }
    return 0;
}
