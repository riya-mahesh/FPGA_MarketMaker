// This file was generated with the help of Claude Code.
//
// Types internal to the pipeline (not wire messages; those are in
// messages_pkg).
//
// Market data events and execution reports travel down one pipeline, merged
// into a single ordered stream. Each item (a pipeline_item_t) is one or the
// other (see `source`), plus the errors found so far. Each check stage ORs in
// its own error bit and passes the item on, so an error always stays attached
// to the message it applies to, however many stages there are. The quote
// manager then makes one decision from the accumulated errors.
package pipeline_pkg;

    // Errors derived from the market data stream. Errors that depend on the
    // quote being decided (the position limit) or on state the CPU writes (the
    // loss limit) are not here: the quote manager computes or reads those itself.
    typedef struct packed {
        logic book_overflow; // a side of the book needed more levels than it can hold,
                             // at or before this item, so it can no longer be trusted
                             // (sticky)
        logic unknown_order; // the feed referred to an order the order table doesn't
                             // hold, at or before this item, so the book can no longer
                             // be trusted (sticky)
        logic sequence_gap;  // a feed message was missed at or before this one (sticky)
        logic book_invalid;  // after this message, a side of the book is empty or crossed
    } error_flags_t;

    typedef enum logic {
        SOURCE_MARKET_DATA,
        SOURCE_REPORT
    } item_source_e;

    // A change to one price level of the book, produced by the order table:
    // `shares` join (add = 1) or leave (add = 0) the level at `price` on one
    // side. Only other participants' orders produce updates: ours are never
    // counted in the book.
    typedef struct packed {
        logic        valid;
        logic        is_buy;
        logic        add;
        logic [31:0] price;   // fixed point, 4 implied decimals
        logic [31:0] shares;
    } level_update_t;

    // One item in the pipeline, from the sequence check through the merge to
    // the order table: either a market data event or an execution report, as
    // `source` says; the other event field is zero.
    typedef struct packed {
        item_source_e                     source;
        messages_pkg::report_event_t      report_event;
        messages_pkg::market_data_event_t market_event;
        error_flags_t                     errors;
    } pipeline_item_t;

    // What the order table passes to the book. Each stage after the order
    // table consumes what it needs and passes on only what later stages use:
    // the order table turns market data events into level updates (nothing
    // after it needs the events themselves), while reports continue on to the
    // quote manager.
    typedef struct packed {
        level_update_t [1:0]              level_updates;  // a replace needs two
        item_source_e                     source;         // a report, or market data
        messages_pkg::report_event_t      report_event;   // reports only; otherwise zero
        error_flags_t                     errors;
    } book_item_t;

    // The best bid and offer, excluding our own orders. A size of 0 means
    // that side of the book is empty.
    typedef struct packed {
        logic [31:0] bid_price;
        logic [31:0] bid_size;
        logic [31:0] ask_price;
        logic [31:0] ask_size;
    } top_of_book_t;

    // What the book passes to pricing: the book's level updates have been
    // applied, leaving only the resulting top of book.
    typedef struct packed {
        top_of_book_t                     top_of_book;   // after this item
        item_source_e                     source;        // a report, or market data
        messages_pkg::report_event_t      report_event;  // reports only; otherwise zero
        error_flags_t                     errors;
    } pricing_item_t;

    // What pricing passes to the quote manager: the quotes we want, given the
    // book after this item.
    typedef struct packed {
        logic                             can_quote;     // the prices below are meaningful
        logic [31:0]                      bid_price;     // desired bid, on the tick grid
        logic [31:0]                      ask_price;     // desired ask, on the tick grid
        item_source_e                     source;        // a report, or market data
        messages_pkg::report_event_t      report_event;  // reports only; otherwise zero
        error_flags_t                     errors;
    } quote_item_t;

endpackage
