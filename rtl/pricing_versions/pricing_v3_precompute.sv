// PRICING VERSION 3 -- PRECOMPUTED CANDIDATES (write-up "V3"; the version in use).
// Change from version 2: the arithmetic after the pick (B + k * tick, the
// credit, the positivity check) moves into stage 1, done for every possible k
// in parallel, so stage 2 only compares, picks k (one-hot) and selects.
// Measured (make timing): pricing alone 40.08 MHz; whole design 41.52 MHz.
// Earlier versions: rtl/pricing_versions/. A copy of this file is kept there
// as pricing_v3_precompute.sv (tests/pricing_versions/ checks they match).
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
// Pipelining. Done in one cycle, this chains a subtract, the spread
// comparisons, a multiply, the k comparisons, a priority pick, another
// multiply (k * tick), and the credit arithmetic: by far the longest path in
// the design. So it is split into two stages, cut where S * bid size becomes
// known, and stage 1 also does in advance everything that doesn't depend on
// it:
//
//   Stage 1: S and S * bid size; and, alongside them (they need only the
//            sizes, prices, and credit), every candidate k * total size and,
//            for every possible k, the bid, ask, and "bid is positive" that
//            k would give.
//   Stage 2: the k comparisons, all at once. The candidates that hold form a
//            prefix (k * total size grows with k), so the largest is the one
//            whose successor fails: found for every k at once (one-hot), not
//            by a chain. It then selects the precomputed prices.
//
// Timing: two registered stages with no state of their own. item_valid is
// high exactly two cycles after in_item_valid. A new item may arrive every
// cycle.
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

    localparam int K_COUNT = MAX_SPREAD_TICKS;  // candidates for k: 0 .. MAX_SPREAD_TICKS-1

    // ---------------------------------------------------------------------
    // Stage 1: S * bid size, and everything stage 2 will choose between.
    // Its results wait in these registers (mid_*) for stage 2.
    // ---------------------------------------------------------------------
    logic               mid_valid, mid_valid_next;                  // stage 1 holds an item
    logic               mid_spread_ok, mid_spread_ok_next;          // 1 <= S <= MAX_SPREAD_TICKS
    logic [36:0]        mid_weighted, mid_weighted_next;            // S * bid size
    logic [K_COUNT-1:0] mid_allowed, mid_allowed_next;              // bit k: k < S
    logic [36:0]        mid_multiple [1:K_COUNT-1];                 // k * total size
    logic [36:0]        mid_multiple_next [1:K_COUNT-1];
    logic [31:0]        mid_bid [K_COUNT];                          // bid if fair value's tick is B + k ticks
    logic [31:0]        mid_bid_next [K_COUNT];
    logic [31:0]        mid_ask [K_COUNT+1];                        // ask if the tick above is B + k ticks
    logic [31:0]        mid_ask_next [K_COUNT+1];
    logic [K_COUNT-1:0] mid_positive, mid_positive_next;            // bit k: that bid would be positive
    item_source_e       mid_source, mid_source_next;                // passed through unchanged
    report_event_t      mid_report_event, mid_report_event_next;
    error_flags_t       mid_errors, mid_errors_next;

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

        // In parallel with the spread: each candidate k * total size, and the
        // prices each k would give (k * tick is a constant per k, so no
        // multiplier is needed).
        for (int j = 1; j < K_COUNT; ++j) begin
            mid_multiple_next[j] = 37'(j) * {4'd0, total_size};
        end
        for (int j = 0; j < K_COUNT; ++j) begin
            mid_bid_next[j]      = top.bid_price + 32'(j) * TICK_SIZE - credit;
            mid_positive_next[j] = top.bid_price + 32'(j) * TICK_SIZE > credit;
            mid_allowed_next[j]  = j < spread_ticks;
        end
        for (int j = 0; j <= K_COUNT; ++j) begin
            mid_ask_next[j] = top.bid_price + 32'(j) * TICK_SIZE + credit;
        end

        mid_valid_next        = in_item_valid;
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
        mid_spread_ok    <= mid_spread_ok_next;
        mid_weighted     <= mid_weighted_next;
        mid_allowed      <= mid_allowed_next;
        mid_multiple     <= mid_multiple_next;
        mid_bid          <= mid_bid_next;
        mid_ask          <= mid_ask_next;
        mid_positive     <= mid_positive_next;
        mid_source       <= mid_source_next;
        mid_report_event <= mid_report_event_next;
        mid_errors       <= mid_errors_next;
    end

    // ---------------------------------------------------------------------
    // Stage 2: find k, and select the prices stage 1 prepared for it.
    // ---------------------------------------------------------------------
    logic        item_valid_next;
    quote_item_t item_next;

    always_comb begin
        logic [K_COUNT:0]   fits;     // bit k: k < S and k * total size <= S * bid size
        logic [K_COUNT-1:0] exact;    // bit k: k * total size == S * bid size (on a tick)
        logic [K_COUNT-1:0] chosen;   // bit k: k is the largest that fits (one-hot)
        logic [31:0]        bid;
        logic [31:0]        ask;
        logic               positive;
        logic               can_quote;

        // Every comparison at once. k = 0 always fits.
        fits[0]  = 1'b1;
        exact[0] = mid_weighted == '0;
        for (int j = 1; j < K_COUNT; ++j) begin
            fits[j]  = mid_allowed[j] && mid_multiple[j] <= mid_weighted;
            exact[j] = mid_multiple[j] == mid_weighted;
        end
        fits[K_COUNT] = 1'b0;

        // The fits form a prefix (1...10...0), so the largest k that fits is
        // the one whose successor doesn't.
        for (int j = 0; j < K_COUNT; ++j) begin
            chosen[j] = fits[j] && !fits[j + 1];
        end

        // Select k's precomputed prices: OR together the one chosen entry.
        // On a tick, the tick above is k's own; otherwise it is k + 1's.
        bid      = '0;
        ask      = '0;
        positive = 1'b0;
        for (int j = 0; j < K_COUNT; ++j) begin
            if (chosen[j]) begin
                bid      = bid | mid_bid[j];
                ask      = ask | (exact[j] ? mid_ask[j] : mid_ask[j + 1]);
                positive = positive | mid_positive[j];
            end
        end

        can_quote = !mid_errors.book_invalid && mid_spread_ok && positive;

        item_valid_next        = mid_valid;
        item_next              = '0;
        item_next.can_quote    = can_quote;
        item_next.bid_price    = can_quote ? bid : '0;
        item_next.ask_price    = can_quote ? ask : '0;
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
