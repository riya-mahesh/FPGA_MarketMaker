// Pricing V1. Change from V0: a register after S * bid size splits pricing
// into two stages; k * total size and the k < S mask move to stage 1,
// alongside the spread. Stage 2 still picks k with a priority chain, then
// computes B + k * tick and applies the credit.
// Measured: pricing alone 35.51 MHz, whole design 29.00 MHz.
// Stage 2 reads the credit a cycle after the item entered; this matches V0
// because the CPU writes the credit only between messages.
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
// Timing: two registered stages with no state of their own. item_valid is
// high exactly two cycles after in_item_valid.
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

    // ---------------------------------------------------------------------
    // Stage 1: results wait in these mid_* registers for stage 2.
    // ---------------------------------------------------------------------
    logic                    mid_valid, mid_valid_next;                // stage 1 holds an item
    logic [31:0]             mid_bid_price, mid_bid_price_next;        // B, for the ticks
    logic                    mid_spread_ok, mid_spread_ok_next;        // 1 <= S <= MAX_SPREAD_TICKS
    logic [MAX_SPREAD_TICKS-1:0] mid_k_allowed, mid_k_allowed_next;    // bit k: k < S
    logic [36:0]             mid_weighted, mid_weighted_next;          // S * bid size
    logic [36:0]             mid_multiple [1:MAX_SPREAD_TICKS-1];      // k * total size
    logic [36:0]             mid_multiple_next [1:MAX_SPREAD_TICKS-1];
    item_source_e            mid_source, mid_source_next;              // passed through
    report_event_t           mid_report_event, mid_report_event_next;
    error_flags_t            mid_errors, mid_errors_next;

    always_comb begin
        top_of_book_t top;
        logic [31:0]  spread;         // A - B, in price units
        int           spread_ticks;   // S
        logic [32:0]  total_size;     // bid size + ask size

        top        = in_item.top_of_book;
        spread     = top.ask_price - top.bid_price;
        total_size = {1'b0, top.bid_size} + {1'b0, top.ask_size};

        // The spread in ticks, by comparison with each multiple of the tick.
        spread_ticks = 0;
        for (int j = 1; j <= MAX_SPREAD_TICKS; ++j) begin
            if (spread >= j * TICK_SIZE) spread_ticks = j;
        end

        // Every candidate k * total size, alongside S (it needs only the sizes).
        for (int j = 1; j < MAX_SPREAD_TICKS; ++j) begin
            mid_multiple_next[j] = 37'(j) * {4'd0, total_size};
        end

        for (int j = 0; j < MAX_SPREAD_TICKS; ++j) begin
            mid_k_allowed_next[j] = j < spread_ticks;
        end

        mid_valid_next        = in_item_valid;
        mid_bid_price_next    = top.bid_price;
        mid_spread_ok_next    = spread_ticks >= 1 && spread <= MAX_SPREAD_TICKS * TICK_SIZE;
        mid_weighted_next     = 37'(spread_ticks) * {5'd0, top.bid_size};
        mid_source_next       = in_item.source;
        mid_report_event_next = in_item.report_event;
        mid_errors_next       = in_item.errors;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mid_valid <= 1'b0;
        end else begin
            mid_valid <= mid_valid_next;
        end
        // No reset: these only matter when mid_valid is high.
        mid_bid_price    <= mid_bid_price_next;
        mid_spread_ok    <= mid_spread_ok_next;
        mid_k_allowed    <= mid_k_allowed_next;
        mid_weighted     <= mid_weighted_next;
        mid_multiple     <= mid_multiple_next;
        mid_source       <= mid_source_next;
        mid_report_event <= mid_report_event_next;
        mid_errors       <= mid_errors_next;
    end

    // ---------------------------------------------------------------------
    // Stage 2: pick k, form the ticks, apply the credit.
    // ---------------------------------------------------------------------
    logic        item_valid_next;
    quote_item_t item_next;

    always_comb begin
        int           below;          // k: fair value's tick, counted from B
        logic         on_tick;        // fair value is exactly on a tick
        logic [31:0]  tick_below;     // the tick at or below fair value
        logic [31:0]  tick_above;     // the tick at or above fair value
        logic         can_quote;

        // The largest k with k * total size <= S * bid size (k < S), and
        // whether that is an exact equality.
        below   = 0;
        on_tick = mid_weighted == '0;
        for (int j = 1; j < MAX_SPREAD_TICKS; ++j) begin
            if (mid_k_allowed[j] && mid_multiple[j] <= mid_weighted) begin
                below   = j;
                on_tick = mid_multiple[j] == mid_weighted;
            end
        end

        tick_below = mid_bid_price + 32'(below) * TICK_SIZE;
        tick_above = on_tick ? tick_below : tick_below + TICK_SIZE;

        can_quote = !mid_errors.book_invalid
                 && mid_spread_ok
                 && tick_below > credit;

        item_valid_next        = mid_valid;
        item_next              = '0;
        item_next.can_quote    = can_quote;
        item_next.bid_price    = can_quote ? tick_below - credit : '0;
        item_next.ask_price    = can_quote ? tick_above + credit : '0;
        item_next.source       = mid_source;
        item_next.report_event = mid_report_event;
        item_next.errors       = mid_errors;
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
