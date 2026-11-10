// This file was generated with the help of Claude Code.
//
// Order table: remembers every order the market data feed has told us about,
// and turns each item into a book_item_t for the book: market data events
// become level updates (nothing after this stage needs the events
// themselves), and reports are passed on unchanged for the quote manager.
//
// Most feed messages name an order only by its ref ("ref 1234 lost 50
// shares"), so to know which price level changed, the table keeps each live
// order's side, price, and remaining shares. It also tracks which orders are
// ours, because the book must count only other participants' liquidity:
//
//   - An Accepted or Replaced report tells us an order ref is ours. If the
//     feed has already added that order (the usual case: the feed is faster
//     than our acknowledgements), its remaining shares are removed again.
//   - If the report arrives first, the entry is marked as ours before the
//     feed's Add, and the Add then adds nothing.
//   - A replacement inherits "ours" from the order it replaces.
//
// So an order's shares are in the book exactly while it is live and not ours.
//
// The table is a block RAM indexed by the low INDEX_BITS bits of the ref.
// Each entry also stores the rest of the ref as a tag, so a newer order that
// lands on the same entry isn't confused with an older one. The table is
// direct-mapped (each ref has exactly one entry), so a new order overwrites
// any older order still resting in that entry (one that rests while
// 2^INDEX_BITS newer orders are entered). The overwritten order's shares are
// still correctly in the book; the book only goes wrong when the feed later
// changes that order and the table can't find it. So any feed message that
// refers to an order the table doesn't hold sets errors.unknown_order, on
// that item and every item after it, and the quote manager stops quoting.
// (On a real exchange, the feed never refers to an order it didn't announce,
// so this only happens when something has gone wrong.) Each item needs
// at most one read and one write, so an item may arrive every cycle. A read
// in the same cycle as the previous item's write to the same entry would
// return stale data, so that write is forwarded instead.
//
// Prices are narrowed to 32 bits here (enough for prices up to $214,748).
//
// Timing: two cycles (read the entry, then update it). item_valid is high
// exactly two cycles after in_item_valid.
module order_table
    import messages_pkg::*;
    import pipeline_pkg::*;
#(
    parameter int INDEX_BITS = 12  // 4K entries
) (
    input  logic           clk,
    input  logic           rst,

    input  logic           in_item_valid,
    input  pipeline_item_t in_item,

    output logic           item_valid,
    output book_item_t     item
);

    localparam int DEPTH    = 1 << INDEX_BITS;
    localparam int TAG_BITS = 64 - INDEX_BITS;

    typedef struct packed {
        logic [TAG_BITS-1:0] tag;     // the ref's upper bits
        logic                live;    // the order is on the book
        logic                own;     // the order is ours
        logic                is_buy;
        logic [31:0]         price;
        logic [31:0]         shares;  // remaining
    } entry_t;

    // The table. It starts empty (all zeros: not live, not ours) and is not
    // cleared by reset.
    entry_t entries [DEPTH];
    initial entries = '{default: '0};

    // ---------------------------------------------------------------------
    // Cycle 1: read the entry while the item waits in a register.
    // ---------------------------------------------------------------------
    logic                  read_valid, read_valid_next;
    pipeline_item_t        read_item, read_item_next;
    logic [63:0]           read_ref, read_ref_next;
    entry_t                read_entry;  // the block RAM's registered output

    // The ref this item looks up: the order a feed message names (for a
    // replace, the original), or the order an Accepted/Replaced report names.
    wire [63:0]           lookup_ref   = in_item.source == SOURCE_MARKET_DATA
                                       ? in_item.market_event.order_ref
                                       : in_item.report_event.order_ref;
    wire [INDEX_BITS-1:0] lookup_index = lookup_ref[INDEX_BITS-1:0];

    always_comb begin
        read_valid_next = in_item_valid;
        read_item_next  = in_item;
        read_ref_next   = lookup_ref;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            read_valid <= 1'b0;
        end else begin
            read_valid <= read_valid_next;
        end
        // No reset: these only matter when read_valid is high.
        read_item <= read_item_next;
        read_ref  <= read_ref_next;
    end

    // The block RAM's read port: registered, so the entry arrives in cycle 2.
    always_ff @(posedge clk) begin
        read_entry <= entries[lookup_index];
    end

    // ---------------------------------------------------------------------
    // Cycle 2: update the entry and produce level updates.
    // ---------------------------------------------------------------------
    logic                  last_write_valid, last_write_valid_next;
    logic [INDEX_BITS-1:0] last_write_index, last_write_index_next;
    entry_t                last_write_entry, last_write_entry_next;

    logic                  write_valid;
    logic [INDEX_BITS-1:0] write_index;
    entry_t                write_entry;

    logic                  unknown_order_seen, unknown_order_seen_next;
    logic                  unknown_order;  // seen at or before this item
    logic                  item_valid_next;
    book_item_t            item_next;

    wire [INDEX_BITS-1:0] read_index = read_ref[INDEX_BITS-1:0];

    // The entry as it really is: the previous item's write, if it went to the
    // same entry in the same cycle as our read; otherwise what the RAM returned.
    wire entry_t entry = (last_write_valid && last_write_index == read_index)
                       ? last_write_entry : read_entry;

    // Does the entry belong to this ref (and not a different, older one)?
    wire hit  = entry.tag == read_ref[63:INDEX_BITS];
    wire live = hit && entry.live;
    wire own  = hit && entry.own;

    // The change to one level, as a level update.
    function automatic level_update_t level_update(logic is_buy, logic add,
                                                   logic [31:0] price, logic [31:0] shares);
        level_update_t update;
        update.valid  = 1'b1;
        update.is_buy = is_buy;
        update.add    = add;
        update.price  = price;
        update.shares = shares;
        return update;
    endfunction

    // Shorthand for the item's market data event (only some fields are used here).
    /* verilator lint_off UNUSEDSIGNAL */
    wire market_data_event_t market = read_item.market_event;
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        logic [31:0] removed;

        write_valid = 1'b0;
        write_index = read_index;
        write_entry = entry;

        unknown_order          = unknown_order_seen;
        item_valid_next        = read_valid;
        item_next              = '0;
        item_next.source       = read_item.source;
        item_next.report_event = read_item.report_event;
        item_next.errors       = read_item.errors;
        removed                = '0;

        if (read_valid && read_item.source == SOURCE_MARKET_DATA) begin
            case (market.kind)
                MARKET_DATA_ADD: begin
                    // Keep "ours" if a report already marked this ref.
                    write_valid        = 1'b1;
                    write_entry.tag    = read_ref[63:INDEX_BITS];
                    write_entry.live   = 1'b1;
                    write_entry.own    = own;
                    write_entry.is_buy = market.is_buy;
                    write_entry.price  = market.price[31:0];
                    write_entry.shares = market.shares;
                    if (!own) begin
                        item_next.level_updates[0] =
                            level_update(market.is_buy, 1'b1, market.price[31:0], market.shares);
                    end
                end
                MARKET_DATA_EXECUTED, MARKET_DATA_CANCEL, MARKET_DATA_DELETE: begin
                    if (!live) begin
                        unknown_order = 1'b1;
                    end else begin
                        // A delete removes everything that's left.
                        removed = (market.kind == MARKET_DATA_DELETE || market.shares > entry.shares)
                                ? entry.shares : market.shares;
                        write_valid        = 1'b1;
                        write_entry.shares = entry.shares - removed;
                        write_entry.live   = entry.shares != removed;
                        if (!own) begin
                            item_next.level_updates[0] =
                                level_update(entry.is_buy, 1'b0, entry.price, removed);
                        end
                    end
                end
                MARKET_DATA_REPLACE: begin
                    // The original order (the one looked up) leaves the book and
                    // a new one, on the same side, joins it. The original's entry
                    // is left as is: the feed never mentions a replaced ref again.
                    if (!live) begin
                        unknown_order = 1'b1;
                    end else begin
                        write_valid        = 1'b1;
                        write_index        = market.new_order_ref[INDEX_BITS-1:0];
                        write_entry.tag    = market.new_order_ref[63:INDEX_BITS];
                        write_entry.live   = 1'b1;
                        write_entry.own    = own;  // a replacement of ours is ours
                        write_entry.is_buy = entry.is_buy;
                        write_entry.price  = market.price[31:0];
                        write_entry.shares = market.shares;
                        if (!own) begin
                            item_next.level_updates[0] =
                                level_update(entry.is_buy, 1'b0, entry.price, entry.shares);
                            item_next.level_updates[1] =
                                level_update(entry.is_buy, 1'b1, market.price[31:0], market.shares);
                        end
                    end
                end
                default: begin
                end
            endcase
        end else if (read_valid && (read_item.report_event.kind == REPORT_ACCEPTED ||
                                    read_item.report_event.kind == REPORT_REPLACED)) begin
            // This ref is ours. If the feed already added it, take it back out.
            write_valid      = 1'b1;
            write_entry.own  = 1'b1;
            if (!hit) begin
                write_entry      = '0;
                write_entry.tag  = read_ref[63:INDEX_BITS];
                write_entry.own  = 1'b1;
            end
            if (live && !own) begin
                item_next.level_updates[0] =
                    level_update(entry.is_buy, 1'b0, entry.price, entry.shares);
            end
        end

        // Sticky: this item and every later one carry the flag.
        unknown_order_seen_next        = unknown_order;
        item_next.errors.unknown_order = unknown_order;

        last_write_valid_next = write_valid;
        last_write_index_next = write_index;
        last_write_entry_next = write_entry;
    end

    // The block RAM's write port.
    always_ff @(posedge clk) begin
        if (write_valid) begin
            entries[write_index] <= write_entry;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            last_write_valid   <= 1'b0;
            unknown_order_seen <= 1'b0;
            item_valid         <= 1'b0;
        end else begin
            last_write_valid   <= last_write_valid_next;
            unknown_order_seen <= unknown_order_seen_next;
            item_valid         <= item_valid_next;
        end
        // No reset: these only matter when the matching valid bit is high.
        last_write_index <= last_write_index_next;
        last_write_entry <= last_write_entry_next;
        item             <= item_next;
    end

endmodule
