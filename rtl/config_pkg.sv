// This file was generated with the help of Claude Code.
//
// Fixed strategy parameters, and the register map the CPU uses to talk to
// the FPGA.
//
// The parameters are part of the fixed behavior: changing any of them changes
// the order stream. (Parameters only the CPU's cold path uses, such as the
// volatility multiplier and the loss limit, live in the C++ code instead.)
//
// A package is a shared set of definitions: no single module uses all of
// them, so Verilator's unused-parameter warning is off inside it.
/* verilator lint_off UNUSEDPARAM */
package config_pkg;

    // -----------------------------------------------------------------------
    // Strategy parameters
    // -----------------------------------------------------------------------

    // Size of each quote, in shares.
    localparam logic [31:0] QUOTE_SHARES = 32'd100;

    // Maximum absolute position, in shares.
    localparam logic [31:0] POSITION_LIMIT = 32'd500;

    // Minimum half-spread, in price units ($0.01). The credit register starts
    // here, so quotes are sensible before the CPU's first update.
    localparam logic [31:0] MIN_CREDIT = 32'd100;

    // The exchange's tick size, in price units ($0.01). The credit the CPU
    // writes must be a whole number of ticks (it rounds up).
    localparam logic [31:0] TICK_SIZE = 32'd100;

    // The widest market we quote into, in ticks ($0.16). Pricing finds where
    // fair value falls within the spread by comparing against each tick at
    // once, so this bounds the hardware; wider markets aren't quoted.
    localparam int MAX_SPREAD_TICKS = 16;

    // -----------------------------------------------------------------------
    // Register map (the C++ cold path uses the same addresses)
    // -----------------------------------------------------------------------

    localparam int REGISTER_ADDRESS_BITS = 8;

    // Written by the CPU.
    localparam logic [7:0] REGISTER_CREDIT   = 8'd0;  // half-spread, price units, whole ticks (low 32 bits)
    localparam logic [7:0] REGISTER_HALT     = 8'd1;  // nonzero: cancel everything, stop quoting

    // Read by the CPU.
    localparam logic [7:0] REGISTER_POSITION = 8'd2;  // shares, signed (positive = long)
    localparam logic [7:0] REGISTER_CASH     = 8'd3;  // realized cash, price units x shares, signed
    localparam logic [7:0] REGISTER_MID      = 8'd4;  // bit 63: book valid; low 32 bits: (bid + ask) / 2

endpackage
/* verilator lint_on UNUSEDPARAM */
