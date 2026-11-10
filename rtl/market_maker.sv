// This file was generated with the help of Claude Code.
//
// The market maker's hot path: every stage, wired together. This is the top
// of the design; the C++ adapter drives its ports the way a network card and
// PCIe would on a real board.
//
//   market data --> market_data_parser --> sequence_check --+
//                                                            |
//   reports ------> report_parser ------------------------> merge
//                                                            |
//                                                       order_table
//                                                            |
//                                                           book
//                                                            |
//                         +---- mid -------------------------|
//                         |                                  |
//                    register_bank --- credit ---------> pricing
//                         ^   |                              |
//                         |   +------- halt -----------> quote_manager
//                         +---- position, cash ------------- |
//                                                       order_encoder --> orders
//
// Messages in and out are whole, one per valid cycle, with byte 0 in bits
// [7:0]. Market data and reports may arrive on the same cycle; the merge
// orders them and hands the rest of the pipeline at most one item every two
// cycles.
module market_maker
    import config_pkg::*;
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic                             clk,
    input  logic                             rst,

    // From the exchange.
    input  logic                             market_data_valid,
    input  logic [MESSAGE_BITS-1:0]          market_data,
    input  logic                             report_valid,
    input  logic [MESSAGE_BITS-1:0]          report,

    // To the exchange.
    output logic                             order_valid,
    output logic [MESSAGE_BITS-1:0]          order,

    // The CPU's register bus (see config_pkg for the map).
    input  logic                             register_write_valid,
    input  logic [REGISTER_ADDRESS_BITS-1:0] register_write_address,
    input  logic [63:0]                      register_write_data,
    input  logic [REGISTER_ADDRESS_BITS-1:0] register_read_address,
    output logic [63:0]                      register_read_data,

    // Sticky: the merge lost a message because messages arrived faster than
    // the pipeline accepts them. Nothing downstream can be trusted after it.
    output logic                             overflow
);

    // Market data side.
    logic               market_event_valid;
    market_data_event_t market_event;
    logic               market_item_valid;
    pipeline_item_t     market_item;

    // Report side.
    logic               report_event_valid;
    report_event_t      report_event;

    // The merged pipeline.
    logic               merged_item_valid;
    pipeline_item_t     merged_item;
    logic               book_item_valid;
    book_item_t         book_item;
    logic               pricing_item_valid;
    pricing_item_t      pricing_item;
    logic               quote_item_valid;
    quote_item_t        quote_item;
    logic               request_valid;
    order_request_t     request;

    // Between the register bank and the pipeline.
    logic [31:0]        credit;
    logic               halt;
    logic signed [31:0] position;
    logic signed [63:0] cash;

    market_data_parser market_data_parser (
        .clk, .rst,
        .in_valid           (market_data_valid),
        .in_data            (market_data),
        .market_event_valid,
        .market_event
    );

    sequence_check sequence_check (
        .clk, .rst,
        .market_event_valid,
        .market_event,
        .item_valid         (market_item_valid),
        .item               (market_item)
    );

    report_parser report_parser (
        .clk, .rst,
        .in_valid           (report_valid),
        .in_data            (report),
        .report_event_valid,
        .report_event
    );

    merge merge (
        .clk, .rst,
        .market_item_valid,
        .market_item,
        .report_event_valid,
        .report_event,
        .item_valid         (merged_item_valid),
        .item               (merged_item),
        .overflow
    );

    order_table order_table (
        .clk, .rst,
        .in_item_valid      (merged_item_valid),
        .in_item            (merged_item),
        .item_valid         (book_item_valid),
        .item               (book_item)
    );

    book book (
        .clk, .rst,
        .in_item_valid      (book_item_valid),
        .in_item            (book_item),
        .item_valid         (pricing_item_valid),
        .item               (pricing_item)
    );

    pricing pricing (
        .clk, .rst,
        .in_item_valid      (pricing_item_valid),
        .in_item            (pricing_item),
        .credit,
        .item_valid         (quote_item_valid),
        .item               (quote_item)
    );

    quote_manager quote_manager (
        .clk, .rst,
        .in_item_valid      (quote_item_valid),
        .in_item            (quote_item),
        .halt_request       (halt),
        .request_valid,
        .request,
        .position,
        .cash
    );

    order_encoder order_encoder (
        .clk, .rst,
        .request_valid,
        .request,
        .order_valid,
        .order_data         (order)
    );

    register_bank register_bank (
        .clk, .rst,
        .write_valid        (register_write_valid),
        .write_address      (register_write_address),
        .write_data         (register_write_data),
        .read_address       (register_read_address),
        .read_data          (register_read_data),
        .credit,
        .halt,
        .position,
        .cash,
        .book_update_valid  (pricing_item_valid),
        .book_valid         (!pricing_item.errors.book_invalid),
        .bid_price          (pricing_item.top_of_book.bid_price),
        .ask_price          (pricing_item.top_of_book.ask_price)
    );

endmodule
