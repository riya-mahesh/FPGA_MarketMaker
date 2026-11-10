// This file was generated with the help of Claude Code.
//
// Book: applies the order table's level updates to the top LEVELS price
// levels of each side, and produces the top of book (the best bid and offer,
// excluding our own orders) for pricing.
//
// Each side is a sorted list in registers, best price first: bids highest
// first, asks lowest first. An update compares its price against every level
// at once (in parallel), then either changes that level's size, removes the
// level (shifting the worse levels up), or inserts a new level (shifting the
// worse levels down). Reading the top of book is free: it is level 0 of each
// side.
//
// An item may carry two updates (a replace). Applying both in one cycle
// would chain a second compare-and-shift onto the first, which is several
// times larger and slower, so each item takes two cycles: update 0 in the
// first, update 1 (if any) in the second. Both cycles use the same update
// logic. This relies on items arriving at least two cycles apart, which the
// merge guarantees.
//
// Only the top LEVELS levels are kept. If a side would need more (a new level
// that is worse than all of them, or one that pushes the worst out), the book
// can no longer be trusted: once those better levels empty, the dropped level
// should have become visible. So errors.book_overflow is set, on that item
// and every item after it, and the quote manager stops quoting. (Real systems
// back a cache like this with a full-depth store and refill it instead.)
//
// errors.book_invalid is set on any item after which a side is empty or the
// book is crossed (best bid at or above best offer).
//
// Timing: two cycles. item_valid is high exactly two cycles after
// in_item_valid, and the item carries the top of book after its updates.
module book
    import messages_pkg::*;
    import pipeline_pkg::*;
#(
    parameter int LEVELS = 16  // per side
) (
    input  logic          clk,
    input  logic          rst,

    // At most one item every two cycles.
    input  logic          in_item_valid,
    input  book_item_t    in_item,

    output logic          item_valid,
    output pricing_item_t item
);

    typedef struct packed {
        logic        valid;
        logic [31:0] price;
        logic [31:0] size;   // total shares resting at this price
    } level_t;

    // One side of the book: level 0 is the best price.
    typedef level_t [LEVELS-1:0] side_t;

    // The result of applying one update to a side.
    typedef struct packed {
        side_t levels;
        logic  overflow;  // a level could not be stored, or was pushed out
    } update_result_t;

    // Is price `a` better than price `b` on this side?
    function automatic logic better(logic is_buy, logic [31:0] a, logic [31:0] b);
        return is_buy ? a > b : a < b;
    endfunction

    // Applies one level update to one side of the book. Positions in the list
    // are bit masks (one bit per level), so each level's new value depends on
    // a couple of bits and its neighbors.
    //
    // All levels are compared with the update at once:
    //   match[i]: level i is at the update's price.
    //   worse[i]: level i is empty or worse, so the new price belongs above it.
    //             The side is sorted with empties last, so this is 0...01...1.
    // Each level then takes its new value from itself or a neighbour: a resize
    // changes the matching level, a remove shifts worse levels up, and an insert
    // puts the new level at the first worse slot and shifts the rest down.
    function automatic update_result_t apply_update(side_t levels, level_update_t update);
        update_result_t    result;
        logic [LEVELS-1:0] match;        // level i is at update.price
        logic [LEVELS-1:0] worse;        // level i is empty or worse than update.price
        logic [LEVELS-1:0] worse_above;  // level i-1 is worse (never, for level 0)
        logic [LEVELS-1:0] empties;      // level i matches and loses all its shares
        side_t             from_below;   // level i+1, for shifting up (the last becomes empty)
        side_t             from_above;   // level i-1, for shifting down
        level_t            new_level;    // the level an insert adds

        // Compare every level with the update, in parallel.
        for (int i = 0; i < LEVELS; ++i) begin
            match[i]   = levels[i].valid && levels[i].price == update.price;
            worse[i]   = !levels[i].valid || better(update.is_buy, update.price, levels[i].price);
            empties[i] = match[i] && !update.add && update.shares >= levels[i].size;
        end
        worse_above = {worse[LEVELS-2:0], 1'b0};

        // Each level's neighbours. % LEVELS only keeps the index in range; the ?: discards it.
        for (int i = 0; i < LEVELS; ++i) begin
            from_below[i] = (i < LEVELS - 1) ? levels[(i + 1) % LEVELS] : '0;
            from_above[i] = (i > 0)          ? levels[(i + LEVELS - 1) % LEVELS] : '0;
        end

        new_level.valid = 1'b1;
        new_level.price = update.price;
        new_level.size  = update.shares;

        // Default: unchanged, no overflow (also for an invalid update).
        result.levels   = levels;
        result.overflow = 1'b0;

        if (update.valid) begin
            if (|empties) begin
                // Remove: the emptied level and every worse one shift up.
                for (int i = 0; i < LEVELS; ++i) begin
                    if (match[i] || worse[i]) result.levels[i] = from_below[i];
                end
            end else if (|match) begin
                // Resize the matching level in place.
                for (int i = 0; i < LEVELS; ++i) begin
                    if (match[i]) begin
                        result.levels[i].size = update.add ? levels[i].size + update.shares
                                                           : levels[i].size - update.shares;
                    end
                end
            end else if (update.add) begin
                // Insert at the first worse slot; the rest shift down. A full side
                // loses its worst level (or can't store a new worst one): overflow.
                for (int i = 0; i < LEVELS; ++i) begin
                    if (worse[i]) result.levels[i] = worse_above[i] ? from_above[i] : new_level;
                end
                result.overflow = levels[LEVELS-1].valid;
            end else begin
                // Shares leaving a level the book doesn't hold: one was dropped earlier.
                result.overflow = 1'b1;
            end
        end
        return result;
    endfunction

    // ---------------------------------------------------------------------
    // Registers: both sides of the book, the sticky overflow, the item
    // between its two cycles, and the output.
    // ---------------------------------------------------------------------
    side_t         bids, bids_next;
    side_t         asks, asks_next;
    logic          overflow_seen, overflow_seen_next;
    logic          second_cycle, second_cycle_next;  // pending_item is in its second cycle
    book_item_t    pending_item, pending_item_next;
    logic          item_valid_next;
    pricing_item_t item_next;

    always_comb begin
        level_update_t  update;        // the update due this cycle
        update_result_t result;
        side_t          bids_updated;  // the book after this cycle's update
        side_t          asks_updated;
        logic           overflow;      // seen at or before this cycle

        // First cycle of an item: its update 0. Second cycle: its update 1.
        update = second_cycle ? pending_item.level_updates[1] : in_item.level_updates[0];
        if (!second_cycle && !in_item_valid) begin
            update = '0;
        end

        bids_updated = bids;
        asks_updated = asks;
        if (update.is_buy) begin
            result       = apply_update(bids, update);
            bids_updated = result.levels;
        end else begin
            result       = apply_update(asks, update);
            asks_updated = result.levels;
        end
        overflow = overflow_seen || result.overflow;

        bids_next          = bids_updated;
        asks_next          = asks_updated;
        overflow_seen_next = overflow;

        // The item waits here during its second cycle.
        second_cycle_next = !second_cycle && in_item_valid;
        pending_item_next = in_item;

        // After the second cycle, the item leaves with the resulting top of book.
        item_valid_next                 = second_cycle;
        item_next                       = '0;
        item_next.top_of_book.bid_price = bids_updated[0].price;
        item_next.top_of_book.bid_size  = bids_updated[0].size;
        item_next.top_of_book.ask_price = asks_updated[0].price;
        item_next.top_of_book.ask_size  = asks_updated[0].size;
        item_next.source                = pending_item.source;
        item_next.report_event          = pending_item.report_event;
        item_next.errors                = pending_item.errors;
        item_next.errors.book_overflow  = overflow;
        item_next.errors.book_invalid   = !bids_updated[0].valid || !asks_updated[0].valid
                                       || bids_updated[0].price >= asks_updated[0].price;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bids          <= '0;
            asks          <= '0;
            overflow_seen <= 1'b0;
            second_cycle  <= 1'b0;
            item_valid    <= 1'b0;
        end else begin
            bids          <= bids_next;
            asks          <= asks_next;
            overflow_seen <= overflow_seen_next;
            second_cycle  <= second_cycle_next;
            item_valid    <= item_valid_next;
        end
        // No reset: these only matter when second_cycle / item_valid is high.
        pending_item <= pending_item_next;
        item         <= item_next;
    end

endmodule
