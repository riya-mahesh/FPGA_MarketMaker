// This file was generated with the help of Claude Code.
//
// Wire messages: type bytes and field offsets for market data (matching
// sim/messages/market_data.h), order entry requests (matching
// sim/messages/order_entry.h), and execution reports (matching
// sim/messages/execution_report.h); the decoded events the two parsers
// produce; and the order request the encoder consumes.
//
// Messages are little-endian packed structs, so a field n bytes long at byte
// offset o is the bit slice data[8*o +: 8*n].
//
// A package is a shared set of definitions: no single module uses all of
// them, so Verilator's unused-parameter warning is off inside it.
/* verilator lint_off UNUSEDPARAM */
package messages_pkg;

    // Width of every message bus: one whole message per valid cycle, padded
    // with zero bytes (sim::kMaxPacketSize = 64 bytes).
    localparam int MESSAGE_BITS = 512;

    // Message type (byte 0 of every message). Market data, order entry
    // requests, and execution reports travel on separate buses, so the same
    // byte can mean different messages on each.
    localparam logic [7:0] TYPE_ADD      = 8'h41;  // 'A' market data: AddOrder
    localparam logic [7:0] TYPE_DELETE   = 8'h44;  // 'D' market data: OrderDelete
    localparam logic [7:0] TYPE_ENTER    = 8'h4F;  // 'O' order entry: EnterOrder
    localparam logic [7:0] TYPE_ACCEPTED = 8'h41;  // 'A' report: Accepted
    localparam logic [7:0] TYPE_REPLACED = 8'h55;  // 'U' report: Replaced
    localparam logic [7:0] TYPE_REJECTED = 8'h4A;  // 'J' report: Rejected
    localparam logic [7:0] TYPE_CANCELED = 8'h43;  // 'C' report: Canceled
    localparam logic [7:0] TYPE_REPLACE  = 8'h55;  // 'U' market data: OrderReplace; order entry: ReplaceOrder
    localparam logic [7:0] TYPE_CANCEL   = 8'h58;  // 'X' market data: OrderCancel (partial); order entry: CancelOrder
    localparam logic [7:0] TYPE_EXECUTED = 8'h45;  // 'E' market data: OrderExecuted; report: Executed

    // Side byte. When parsing, anything other than 'B' is a sell.
    localparam logic [7:0] SIDE_BUY  = 8'h42;  // 'B'
    localparam logic [7:0] SIDE_SELL = 8'h53;  // 'S'

    // -----------------------------------------------------------------------
    // Market data
    // -----------------------------------------------------------------------

    // Header (every message): type 0, instrument 1-2, sequence 3-10,
    // timestamp 11-18. Every message then has its order ref at 19.

    // Field offsets, in bytes.
    localparam int MARKET_SEQUENCE_OFFSET              = 3;   // 8 bytes (every message)
    localparam int MARKET_ORDER_REF_OFFSET             = 19;  // 8 bytes (every message; for a replace, the original)
    localparam int MARKET_ADD_SIDE_OFFSET              = 27;  // 1 byte
    localparam int MARKET_ADD_SHARES_OFFSET            = 28;  // 4 bytes
    localparam int MARKET_ADD_PRICE_OFFSET             = 32;  // 8 bytes
    localparam int MARKET_EXECUTED_SHARES_OFFSET       = 27;  // 4 bytes
    localparam int MARKET_CANCEL_SHARES_OFFSET         = 27;  // 4 bytes
    localparam int MARKET_REPLACE_NEW_ORDER_REF_OFFSET = 27;  // 8 bytes
    localparam int MARKET_REPLACE_SHARES_OFFSET        = 35;  // 4 bytes
    localparam int MARKET_REPLACE_PRICE_OFFSET         = 39;  // 8 bytes

    typedef enum logic [2:0] {
        MARKET_DATA_ADD,
        MARKET_DATA_EXECUTED,
        MARKET_DATA_CANCEL,
        MARKET_DATA_DELETE,
        MARKET_DATA_REPLACE
    } market_data_kind_e;

    // One decoded market data message: only the fields the hot path uses.
    // Fields a message doesn't carry are zero.
    typedef struct packed {
        market_data_kind_e kind;
        logic [63:0]       sequence_number;  // feed sequence number
        logic [63:0]       order_ref;        // for a replace: the original order's ref
        logic [63:0]       new_order_ref;    // replace only: the new order's ref
        logic              is_buy;           // add only
        logic [31:0]       shares;           // add/replace: size; executed/cancel: shares removed
        logic [63:0]       price;            // add/replace: fixed point, 4 implied decimals
    } market_data_event_t;

    // -----------------------------------------------------------------------
    // Execution reports
    // -----------------------------------------------------------------------

    // Header (every report): type 0, sequence 1-8, timestamp 9-16.

    // Body field offsets, in bytes.
    localparam int REPORT_TOKEN_OFFSET                   = 17;  // 8 bytes (every report; for Replaced, the replacement token)
    localparam int REPORT_ACCEPTED_SIDE_OFFSET           = 25;  // 1 byte
    localparam int REPORT_ACCEPTED_SHARES_OFFSET         = 26;  // 4 bytes
    localparam int REPORT_ACCEPTED_PRICE_OFFSET          = 32;  // 8 bytes
    localparam int REPORT_ACCEPTED_ORDER_REF_OFFSET      = 41;  // 8 bytes
    localparam int REPORT_REPLACED_PREVIOUS_TOKEN_OFFSET = 25;  // 8 bytes
    localparam int REPORT_REPLACED_SIDE_OFFSET           = 33;  // 1 byte
    localparam int REPORT_REPLACED_SHARES_OFFSET         = 34;  // 4 bytes
    localparam int REPORT_REPLACED_PRICE_OFFSET          = 38;  // 8 bytes
    localparam int REPORT_REPLACED_ORDER_REF_OFFSET      = 46;  // 8 bytes
    localparam int REPORT_EXECUTED_SHARES_OFFSET         = 25;  // 4 bytes
    localparam int REPORT_EXECUTED_PRICE_OFFSET          = 29;  // 8 bytes
    localparam int REPORT_CANCELED_SHARES_OFFSET         = 25;  // 4 bytes

    typedef enum logic [2:0] {
        REPORT_ACCEPTED,
        REPORT_REPLACED,
        REPORT_EXECUTED,
        REPORT_REJECTED,
        REPORT_CANCELED
    } report_kind_e;

    // One decoded execution report: only the fields the hot path uses.
    // Fields a report doesn't carry are zero.
    typedef struct packed {
        report_kind_e kind;
        logic [63:0]  token;           // our order's token (for Replaced: the replacement)
        logic [63:0]  previous_token;  // Replaced only: the order it replaced
        logic         is_buy;          // Accepted/Replaced
        logic [31:0]  shares;          // Accepted/Replaced: size; Executed: filled; Canceled: removed
        logic [63:0]  price;           // Accepted/Replaced: order price; Executed: fill price
        logic [63:0]  order_ref;       // Accepted/Replaced: the exchange's ref for the order
    } report_event_t;

    // -----------------------------------------------------------------------
    // Order entry (requests we send)
    // -----------------------------------------------------------------------

    // The simulator trades a single instrument (sim::kInstrument).
    localparam logic [15:0] INSTRUMENT = 16'd1;

    // Time in force. Our quotes always rest on the book, so they are Day orders.
    localparam logic [7:0] TIME_IN_FORCE_DAY = 8'h44;  // 'D'

    // Field offsets, in bytes. Requests have no header beyond the type (byte 0).
    localparam int ORDER_ENTER_TOKEN_OFFSET              = 1;   // 8 bytes
    localparam int ORDER_ENTER_SIDE_OFFSET               = 9;   // 1 byte
    localparam int ORDER_ENTER_SHARES_OFFSET             = 10;  // 4 bytes
    localparam int ORDER_ENTER_INSTRUMENT_OFFSET         = 14;  // 2 bytes
    localparam int ORDER_ENTER_PRICE_OFFSET              = 16;  // 8 bytes
    localparam int ORDER_ENTER_TIME_IN_FORCE_OFFSET      = 24;  // 1 byte
    localparam int ORDER_REPLACE_EXISTING_TOKEN_OFFSET   = 1;   // 8 bytes
    localparam int ORDER_REPLACE_REPLACEMENT_TOKEN_OFFSET = 9;  // 8 bytes
    localparam int ORDER_REPLACE_SHARES_OFFSET           = 17;  // 4 bytes
    localparam int ORDER_REPLACE_PRICE_OFFSET            = 21;  // 8 bytes
    localparam int ORDER_CANCEL_TOKEN_OFFSET             = 1;   // 8 bytes
    localparam int ORDER_CANCEL_SHARES_OFFSET            = 9;   // 4 bytes (shares remaining)

    typedef enum logic [1:0] {
        ORDER_ENTER,
        ORDER_REPLACE,
        ORDER_CANCEL
    } order_kind_e;

    // One order to send. Fields a request doesn't use are ignored.
    typedef struct packed {
        order_kind_e kind;
        logic [63:0] token;           // enter: the new order; replace: the replacement; cancel: the order to cancel
        logic [63:0] existing_token;  // replace only: the order being replaced
        logic        is_buy;          // enter only (a replacement keeps its side)
        logic [31:0] shares;          // enter/replace: size; cancel: shares remaining (0 cancels)
        logic [63:0] price;           // enter/replace: fixed point, 4 implied decimals
    } order_request_t;

endpackage
/* verilator lint_on UNUSEDPARAM */
