// This file was generated with the help of Claude Code.
//
// Order encoder: turns one order_request_t per valid cycle into a whole order
// entry message (EnterOrder, ReplaceOrder, or CancelOrder).
//
// Timing: the message is registered, so order_valid is high exactly one cycle
// after request_valid. A new request may arrive every cycle. The message's
// length is implied by its type byte; bytes past the end are zero.
module order_encoder
    import messages_pkg::*;
(
    input  logic                    clk,            // clock: registers update on its rising edge
    input  logic                    rst,            // synchronous reset: clears the valid flag

    /* verilator lint_off UNUSEDSIGNAL */           // kept from the stub, which read none of these
    input  logic                    request_valid,  // high: request holds an order to send this cycle
    input  order_request_t          request,        // the order, from the quote manager
    /* verilator lint_on UNUSEDSIGNAL */

    output logic                    order_valid,    // high: order_data holds a message to send
    output logic [MESSAGE_BITS-1:0] order_data      // the encoded message, byte n in bits [8n+7:8n]
);

    // Combinational results, loaded into the output registers on the next edge.
    logic                    order_valid_next;
    logic [MESSAGE_BITS-1:0] order_data_next;

    // Encode: write each field into order_data_next at its byte offset.
    // A field n bytes long at byte o is order_data_next[8*o +: 8*n].
    always_comb begin
        // Defaults: valid if a request arrived; every byte zero, so fields a
        // message doesn't set and bytes past its end stay zero.
        order_valid_next = request_valid;
        order_data_next  = '0;

        // Each kind's type byte and fields.
        case (request.kind)
            ORDER_ENTER: begin  // new order (25 bytes); instrument and time in force are fixed
                order_data_next[7:0]                                     = TYPE_ENTER;
                order_data_next[8*ORDER_ENTER_TOKEN_OFFSET +: 64]        = request.token;
                order_data_next[8*ORDER_ENTER_SIDE_OFFSET +: 8]          = request.is_buy ? SIDE_BUY : SIDE_SELL;
                order_data_next[8*ORDER_ENTER_SHARES_OFFSET +: 32]       = request.shares;
                order_data_next[8*ORDER_ENTER_INSTRUMENT_OFFSET +: 16]   = INSTRUMENT;
                order_data_next[8*ORDER_ENTER_PRICE_OFFSET +: 64]        = request.price;
                order_data_next[8*ORDER_ENTER_TIME_IN_FORCE_OFFSET +: 8] = TIME_IN_FORCE_DAY;
            end
            ORDER_REPLACE: begin  // replace a live order (29 bytes); it keeps its side
                order_data_next[7:0]                                            = TYPE_REPLACE;
                order_data_next[8*ORDER_REPLACE_EXISTING_TOKEN_OFFSET +: 64]    = request.existing_token;  // the old order
                order_data_next[8*ORDER_REPLACE_REPLACEMENT_TOKEN_OFFSET +: 64] = request.token;           // its replacement
                order_data_next[8*ORDER_REPLACE_SHARES_OFFSET +: 32]            = request.shares;
                order_data_next[8*ORDER_REPLACE_PRICE_OFFSET +: 64]             = request.price;
            end
            ORDER_CANCEL: begin  // reduce an order (13 bytes)
                order_data_next[7:0]                                = TYPE_CANCEL;
                order_data_next[8*ORDER_CANCEL_TOKEN_OFFSET +: 64]  = request.token;
                order_data_next[8*ORDER_CANCEL_SHARES_OFFSET +: 32] = request.shares;  // shares remaining: 0 cancels it all
            end
            default: begin
                order_valid_next = 1'b0;  // unknown kind: nothing to send
            end
        endcase
    end

    // Output registers: the message appears one cycle after the request.
    always_ff @(posedge clk) begin
        if (rst) begin
            order_valid <= 1'b0;
        end else begin
            order_valid <= order_valid_next;
        end
        // No reset: the message only matters when order_valid is high.
        order_data <= order_data_next;
    end

endmodule
