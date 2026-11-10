// This file was generated with the help of Claude Code.
//
// Timing wrappers for `make timing`: the whole design, and each module on its
// own, with a register on every input.
//
// Each is placed and routed on its own ("out of context"), with no board
// around it, so nextpnr only times paths that start and end at registers.
// Logic between an input pin and the first register (all of a parser's
// logic, for example) would go untimed. Registering every input here gives
// those paths a starting register, as the previous stage's output register
// (or a real board's network interface and PCIe logic) would.
//
// Outputs aren't registered: every module's outputs already come from
// registers, except the register bank's read data, which the CPU samples on
// its own schedule.

// ---------------------------------------------------------------------------
// The whole design
// ---------------------------------------------------------------------------
module market_maker_timing
    import config_pkg::*;
    import messages_pkg::*;
(
    input  logic                             clk,
    input  logic                             rst,

    input  logic                             market_data_valid,
    input  logic [MESSAGE_BITS-1:0]          market_data,
    input  logic                             report_valid,
    input  logic [MESSAGE_BITS-1:0]          report,

    output logic                             order_valid,
    output logic [MESSAGE_BITS-1:0]          order,

    input  logic                             register_write_valid,
    input  logic [REGISTER_ADDRESS_BITS-1:0] register_write_address,
    input  logic [63:0]                      register_write_data,
    input  logic [REGISTER_ADDRESS_BITS-1:0] register_read_address,
    output logic [63:0]                      register_read_data,

    output logic                             overflow
);

    logic                             rst_registered;
    logic                             market_data_valid_registered;
    logic [MESSAGE_BITS-1:0]          market_data_registered;
    logic                             report_valid_registered;
    logic [MESSAGE_BITS-1:0]          report_registered;
    logic                             register_write_valid_registered;
    logic [REGISTER_ADDRESS_BITS-1:0] register_write_address_registered;
    logic [63:0]                      register_write_data_registered;
    logic [REGISTER_ADDRESS_BITS-1:0] register_read_address_registered;

    always_ff @(posedge clk) begin
        rst_registered                    <= rst;
        market_data_valid_registered      <= market_data_valid;
        market_data_registered            <= market_data;
        report_valid_registered           <= report_valid;
        report_registered                 <= report;
        register_write_valid_registered   <= register_write_valid;
        register_write_address_registered <= register_write_address;
        register_write_data_registered    <= register_write_data;
        register_read_address_registered  <= register_read_address;
    end

    market_maker dut (
        .clk,
        .rst                    (rst_registered),
        .market_data_valid      (market_data_valid_registered),
        .market_data            (market_data_registered),
        .report_valid           (report_valid_registered),
        .report                 (report_registered),
        .order_valid,
        .order,
        .register_write_valid   (register_write_valid_registered),
        .register_write_address (register_write_address_registered),
        .register_write_data    (register_write_data_registered),
        .register_read_address  (register_read_address_registered),
        .register_read_data,
        .overflow
    );

endmodule

// ---------------------------------------------------------------------------
// Each module, in pipeline order
// ---------------------------------------------------------------------------
module market_data_parser_timing
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    in_valid,
    input  logic [MESSAGE_BITS-1:0] in_data,
    output logic                    market_event_valid,
    output market_data_event_t      market_event
);

    logic                    rst_registered;
    logic                    in_valid_registered;
    logic [MESSAGE_BITS-1:0] in_data_registered;

    always_ff @(posedge clk) begin
        rst_registered      <= rst;
        in_valid_registered <= in_valid;
        in_data_registered  <= in_data;
    end

    market_data_parser dut (
        .clk,
        .rst      (rst_registered),
        .in_valid (in_valid_registered),
        .in_data  (in_data_registered),
        .market_event_valid,
        .market_event
    );

endmodule

module sequence_check_timing
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic               clk,
    input  logic               rst,
    input  logic               market_event_valid,
    input  market_data_event_t market_event,
    output logic               item_valid,
    output pipeline_item_t     item
);

    logic               rst_registered;
    logic               market_event_valid_registered;
    market_data_event_t market_event_registered;

    always_ff @(posedge clk) begin
        rst_registered                <= rst;
        market_event_valid_registered <= market_event_valid;
        market_event_registered       <= market_event;
    end

    sequence_check dut (
        .clk,
        .rst                (rst_registered),
        .market_event_valid (market_event_valid_registered),
        .market_event       (market_event_registered),
        .item_valid,
        .item
    );

endmodule

module report_parser_timing
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    in_valid,
    input  logic [MESSAGE_BITS-1:0] in_data,
    output logic                    report_event_valid,
    output report_event_t           report_event
);

    logic                    rst_registered;
    logic                    in_valid_registered;
    logic [MESSAGE_BITS-1:0] in_data_registered;

    always_ff @(posedge clk) begin
        rst_registered      <= rst;
        in_valid_registered <= in_valid;
        in_data_registered  <= in_data;
    end

    report_parser dut (
        .clk,
        .rst      (rst_registered),
        .in_valid (in_valid_registered),
        .in_data  (in_data_registered),
        .report_event_valid,
        .report_event
    );

endmodule

module merge_timing
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic           clk,
    input  logic           rst,
    input  logic           market_item_valid,
    input  pipeline_item_t market_item,
    input  logic           report_event_valid,
    input  report_event_t  report_event,
    output logic           item_valid,
    output pipeline_item_t item,
    output logic           overflow
);

    logic           rst_registered;
    logic           market_item_valid_registered;
    pipeline_item_t market_item_registered;
    logic           report_event_valid_registered;
    report_event_t  report_event_registered;

    always_ff @(posedge clk) begin
        rst_registered                <= rst;
        market_item_valid_registered  <= market_item_valid;
        market_item_registered        <= market_item;
        report_event_valid_registered <= report_event_valid;
        report_event_registered       <= report_event;
    end

    merge dut (
        .clk,
        .rst                (rst_registered),
        .market_item_valid  (market_item_valid_registered),
        .market_item        (market_item_registered),
        .report_event_valid (report_event_valid_registered),
        .report_event       (report_event_registered),
        .item_valid,
        .item,
        .overflow
    );

endmodule

module order_table_timing
    import pipeline_pkg::*;
(
    input  logic           clk,
    input  logic           rst,
    input  logic           in_item_valid,
    input  pipeline_item_t in_item,
    output logic           item_valid,
    output book_item_t     item
);

    logic           rst_registered;
    logic           in_item_valid_registered;
    pipeline_item_t in_item_registered;

    always_ff @(posedge clk) begin
        rst_registered           <= rst;
        in_item_valid_registered <= in_item_valid;
        in_item_registered       <= in_item;
    end

    order_table dut (
        .clk,
        .rst           (rst_registered),
        .in_item_valid (in_item_valid_registered),
        .in_item       (in_item_registered),
        .item_valid,
        .item
    );

endmodule

module book_timing
    import pipeline_pkg::*;
(
    input  logic          clk,
    input  logic          rst,
    input  logic          in_item_valid,
    input  book_item_t    in_item,
    output logic          item_valid,
    output pricing_item_t item
);

    logic       rst_registered;
    logic       in_item_valid_registered;
    book_item_t in_item_registered;

    always_ff @(posedge clk) begin
        rst_registered           <= rst;
        in_item_valid_registered <= in_item_valid;
        in_item_registered       <= in_item;
    end

    book dut (
        .clk,
        .rst           (rst_registered),
        .in_item_valid (in_item_valid_registered),
        .in_item       (in_item_registered),
        .item_valid,
        .item
    );

endmodule

module pricing_timing
    import pipeline_pkg::*;
(
    input  logic          clk,
    input  logic          rst,
    input  logic          in_item_valid,
    input  pricing_item_t in_item,
    input  logic [31:0]   credit,
    output logic          item_valid,
    output quote_item_t   item
);

    logic          rst_registered;
    logic          in_item_valid_registered;
    pricing_item_t in_item_registered;
    logic [31:0]   credit_registered;

    always_ff @(posedge clk) begin
        rst_registered           <= rst;
        in_item_valid_registered <= in_item_valid;
        in_item_registered       <= in_item;
        credit_registered        <= credit;
    end

    pricing dut (
        .clk,
        .rst           (rst_registered),
        .in_item_valid (in_item_valid_registered),
        .in_item       (in_item_registered),
        .credit        (credit_registered),
        .item_valid,
        .item
    );

endmodule

module quote_manager_timing
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic               clk,
    input  logic               rst,
    input  logic               in_item_valid,
    input  quote_item_t        in_item,
    input  logic               halt_request,
    output logic               request_valid,
    output order_request_t     request,
    output logic signed [31:0] position,
    output logic signed [63:0] cash
);

    logic        rst_registered;
    logic        in_item_valid_registered;
    quote_item_t in_item_registered;
    logic        halt_request_registered;

    always_ff @(posedge clk) begin
        rst_registered           <= rst;
        in_item_valid_registered <= in_item_valid;
        in_item_registered       <= in_item;
        halt_request_registered  <= halt_request;
    end

    quote_manager dut (
        .clk,
        .rst           (rst_registered),
        .in_item_valid (in_item_valid_registered),
        .in_item       (in_item_registered),
        .halt_request  (halt_request_registered),
        .request_valid,
        .request,
        .position,
        .cash
    );

endmodule

module order_encoder_timing
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    request_valid,
    input  order_request_t          request,
    output logic                    order_valid,
    output logic [MESSAGE_BITS-1:0] order_data
);

    logic           rst_registered;
    logic           request_valid_registered;
    order_request_t request_registered;

    always_ff @(posedge clk) begin
        rst_registered           <= rst;
        request_valid_registered <= request_valid;
        request_registered       <= request;
    end

    order_encoder dut (
        .clk,
        .rst           (rst_registered),
        .request_valid (request_valid_registered),
        .request       (request_registered),
        .order_valid,
        .order_data
    );

endmodule

module register_bank_timing
    import config_pkg::*;
(
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             write_valid,
    input  logic [REGISTER_ADDRESS_BITS-1:0] write_address,
    input  logic [63:0]                      write_data,
    input  logic [REGISTER_ADDRESS_BITS-1:0] read_address,
    output logic [63:0]                      read_data,
    output logic [31:0]                      credit,
    output logic                             halt,
    input  logic signed [31:0]               position,
    input  logic signed [63:0]               cash,
    input  logic                             book_update_valid,
    input  logic                             book_valid,
    input  logic [31:0]                      bid_price,
    input  logic [31:0]                      ask_price
);

    logic                             rst_registered;
    logic                             write_valid_registered;
    logic [REGISTER_ADDRESS_BITS-1:0] write_address_registered;
    logic [63:0]                      write_data_registered;
    logic [REGISTER_ADDRESS_BITS-1:0] read_address_registered;
    logic signed [31:0]               position_registered;
    logic signed [63:0]               cash_registered;
    logic                             book_update_valid_registered;
    logic                             book_valid_registered;
    logic [31:0]                      bid_price_registered;
    logic [31:0]                      ask_price_registered;

    always_ff @(posedge clk) begin
        rst_registered               <= rst;
        write_valid_registered       <= write_valid;
        write_address_registered     <= write_address;
        write_data_registered        <= write_data;
        read_address_registered      <= read_address;
        position_registered          <= position;
        cash_registered              <= cash;
        book_update_valid_registered <= book_update_valid;
        book_valid_registered        <= book_valid;
        bid_price_registered         <= bid_price;
        ask_price_registered         <= ask_price;
    end

    register_bank dut (
        .clk,
        .rst               (rst_registered),
        .write_valid       (write_valid_registered),
        .write_address     (write_address_registered),
        .write_data        (write_data_registered),
        .read_address      (read_address_registered),
        .read_data,
        .credit,
        .halt,
        .position          (position_registered),
        .cash              (cash_registered),
        .book_update_valid (book_update_valid_registered),
        .book_valid        (book_valid_registered),
        .bid_price         (bid_price_registered),
        .ask_price         (ask_price_registered)
    );

endmodule
