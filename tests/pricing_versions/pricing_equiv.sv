// Runs the original (pricing_ref) and a version (pricing) side by side, delays
// the original's output to match the version's latency, and flags differences.
module pricing_equiv
    import config_pkg::*;
    import messages_pkg::*;
    import pipeline_pkg::*;
#(
    parameter int LATENCY = 2  // the version's latency, in cycles
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        in_valid,
    input  logic [31:0] bid_price, bid_size, ask_price, ask_size,
    input  logic        book_invalid,
    input  logic [31:0] credit,
    output logic        both_valid,
    output logic        mismatch,
    output logic        can_quote,
    output logic [31:0] new_bid, new_ask, ref_bid, ref_ask
);
    pricing_item_t in_item;
    always_comb begin
        in_item = '0;
        in_item.top_of_book.bid_price = bid_price;
        in_item.top_of_book.bid_size  = bid_size;
        in_item.top_of_book.ask_price = ask_price;
        in_item.top_of_book.ask_size  = ask_size;
        in_item.errors.book_invalid   = book_invalid;
    end

    logic        ref_valid, new_valid;
    quote_item_t ref_item, new_item;
    pricing_ref r (.clk, .rst, .in_item_valid(in_valid), .in_item, .credit,
                   .item_valid(ref_valid), .item(ref_item));
    pricing     n (.clk, .rst, .in_item_valid(in_valid), .in_item, .credit,
                   .item_valid(new_valid), .item(new_item));

    // Delay the original's output by LATENCY - 1 cycles.
    logic        ref_valid_d [LATENCY];
    quote_item_t ref_item_d  [LATENCY];
    always_comb begin
        ref_valid_d[0] = ref_valid;
        ref_item_d[0]  = ref_item;
    end
    for (genvar i = 1; i < LATENCY; ++i) begin : delay
        always_ff @(posedge clk) begin
            ref_valid_d[i] <= rst ? 1'b0 : ref_valid_d[i-1];
            ref_item_d[i]  <= ref_item_d[i-1];
        end
    end

    wire         ref_out_valid = ref_valid_d[LATENCY-1];
    quote_item_t ref_out;
    assign ref_out    = ref_item_d[LATENCY-1];
    assign both_valid = ref_out_valid && new_valid;
    assign mismatch   = (ref_out_valid != new_valid) || (new_valid && ref_out != new_item);
    assign can_quote  = new_item.can_quote;
    assign new_bid    = new_item.bid_price;
    assign new_ask    = new_item.ask_price;
    assign ref_bid    = ref_out.bid_price;
    assign ref_ask    = ref_out.ask_price;
endmodule
