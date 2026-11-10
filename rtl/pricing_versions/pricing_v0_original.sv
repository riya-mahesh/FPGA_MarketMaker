// PRICING VERSION 0 -- ORIGINAL (as provided with the assignment).
// The whole computation in one clock cycle. Kept for reference and as the
// golden model for the equivalence test (tests/pricing_versions/).
// Measured (make timing): pricing alone 18.88 MHz; whole design 18.10 MHz.
//
// This file was generated with the help of Claude Code.
//
// Pricing: turns the top of book into the quotes we want, without dividing.
//
// Fair value is the microprice of the best bid B and offer A:
//
//     fair value = (B * ask size + A * bid size) / (bid size + ask size)
//
// A divider is far too large and slow for the hot path, but we never need
// fair value itself, only the ticks just below and above it (our quotes are on
// the tick grid). Two facts make those cheap:
//
//   - Fair value lies between B and A. With some algebra,
//         fair value - B = (A - B) * bid size / (bid size + ask size)
//     so if the spread is S ticks, the tick just below fair value is B + k
//     ticks, where k is the largest whole number with
//         k * (bid size + ask size) <= S * bid size.
//     k is between 0 and S - 1, so every candidate is checked at once (one
//     comparison per possible k) and the largest that holds is taken.
//   - The credit is a whole number of ticks (the CPU rounds it up), so
//         bid = (tick at or below fair value) - credit
//         ask = (tick at or above fair value) + credit
//     with no further rounding.
//
// The comparisons bound the spread: markets wider than MAX_SPREAD_TICKS
// aren't quoted. can_quote is false then, when the book is invalid, or when
// the bid would not be positive; the prices are zero whenever it is false.
//
//
// Timing: a registered stage with no state of its own. item_valid is high
// exactly one cycle after in_item_valid.
module pricing
    import config_pkg::*;
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic          clk,
    input  logic          rst,

    input  logic          in_item_valid,
    input  pricing_item_t in_item,

    // From the register bank: the half-spread, a whole number of ticks.
    input  logic [31:0]   credit,

    output logic          item_valid,
    output quote_item_t   item
);

    logic        item_valid_next;
    quote_item_t item_next;

    always_comb begin
        top_of_book_t top;
        logic [31:0]  spread;         // A - B, in price units
        int           spread_ticks;   // S
        logic [32:0]  total_size;     // bid size + ask size
        logic [36:0]  weighted;       // S * bid size
        int           below;          // k: fair value's tick, counted from B
        logic         on_tick;        // fair value is exactly on a tick
        logic [31:0]  tick_below;     // the tick at or below fair value
        logic [31:0]  tick_above;     // the tick at or above fair value
        logic         can_quote;

        top        = in_item.top_of_book;
        spread     = top.ask_price - top.bid_price;
        total_size = {1'b0, top.bid_size} + {1'b0, top.ask_size};

        // The spread in ticks, by comparison with each multiple of the tick.
        spread_ticks = 0;
        for (int j = 1; j <= MAX_SPREAD_TICKS; ++j) begin
            if (spread >= j * TICK_SIZE) spread_ticks = j;
        end
        weighted = 37'(spread_ticks) * {5'd0, top.bid_size};

        // The largest k with k * total size <= S * bid size (k < S), and
        // whether that is an exact equality.
        below   = 0;
        on_tick = weighted == '0;
        for (int j = 1; j < MAX_SPREAD_TICKS; ++j) begin
            if (j < spread_ticks && 37'(j) * {4'd0, total_size} <= weighted) begin
                below   = j;
                on_tick = 37'(j) * {4'd0, total_size} == weighted;
            end
        end

        tick_below = top.bid_price + 32'(below) * TICK_SIZE;
        tick_above = on_tick ? tick_below : tick_below + TICK_SIZE;

        can_quote = !in_item.errors.book_invalid
                 && spread_ticks >= 1
                 && spread <= MAX_SPREAD_TICKS * TICK_SIZE
                 && tick_below > credit;

        item_valid_next        = in_item_valid;
        item_next              = '0;
        item_next.can_quote    = can_quote;
        item_next.bid_price    = can_quote ? tick_below - credit : '0;
        item_next.ask_price    = can_quote ? tick_above + credit : '0;
        item_next.source       = in_item.source;
        item_next.report_event = in_item.report_event;
        item_next.errors       = in_item.errors;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            item_valid <= 1'b0;
        end else begin
            item_valid <= item_valid_next;
        end
        // No reset: the item only matters when item_valid is high.
        item <= item_next;
    end

endmodule
