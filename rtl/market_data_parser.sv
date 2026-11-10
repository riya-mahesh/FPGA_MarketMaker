// This file was generated with the help of Claude Code.
//
// Market data parser: decodes one whole market data message per valid cycle
// into a market_data_event_t.
//
// Timing: the event is registered, so market_event_valid is high exactly one
// cycle after in_valid. A new message may arrive every cycle. Messages of an
// unknown type are ignored (market_event_valid stays low).
module market_data_parser
    import messages_pkg::*;
(
    input  logic                    clk,                 // clock: registers update on its rising edge
    input  logic                    rst,                 // synchronous reset: clears the valid flag

    // One whole message per valid cycle. Byte 0 (the type) is in bits [7:0];
    // bytes past the end of the message are zero. The instrument (there is
    // only one), the timestamp, and the padding are deliberately not decoded.
    /* verilator lint_off UNUSEDSIGNAL */                // those undecoded bits would otherwise fail the build
    input  logic                    in_valid,            // high: in_data holds a message this cycle
    input  logic [MESSAGE_BITS-1:0] in_data,             // the raw message, 64 bytes, byte n in bits [8n+7:8n]
    /* verilator lint_on UNUSEDSIGNAL */

    output logic                    market_event_valid,  // high: market_event holds a real event
    output market_data_event_t      market_event         // the decoded message fields
);

    // Byte 0: which kind of message this is ('A', 'E', 'X', 'D', 'U').
    wire [7:0] message_type = in_data[7:0];

    // Combinational results, loaded into the output registers on the next edge.
    logic               market_event_valid_next;
    market_data_event_t market_event_next;

    // Decode: pick each field out of in_data at its byte offset.
    // A field n bytes long at byte o is in_data[8*o +: 8*n].
    always_comb begin
        // Defaults: valid if a message arrived; all fields zero, so fields a
        // type doesn't carry stay zero (and nothing is left unassigned).
        market_event_valid_next = in_valid;
        market_event_next       = '0;

        // Fields at the same offset in every type.
        market_event_next.sequence_number = in_data[8*MARKET_SEQUENCE_OFFSET +: 64];
        market_event_next.order_ref       = in_data[8*MARKET_ORDER_REF_OFFSET +: 64];  // original ref for a replace

        // Each type's own fields.
        case (message_type)
            TYPE_ADD: begin  // new order: side, size, price
                market_event_next.kind   = MARKET_DATA_ADD;
                market_event_next.is_buy = in_data[8*MARKET_ADD_SIDE_OFFSET +: 8] == SIDE_BUY;  // 'B' = buy, else sell
                market_event_next.shares = in_data[8*MARKET_ADD_SHARES_OFFSET +: 32];
                market_event_next.price  = in_data[8*MARKET_ADD_PRICE_OFFSET +: 64];
            end
            TYPE_EXECUTED: begin  // part or all of an order traded (match number not decoded)
                market_event_next.kind   = MARKET_DATA_EXECUTED;
                market_event_next.shares = in_data[8*MARKET_EXECUTED_SHARES_OFFSET +: 32];
            end
            TYPE_CANCEL: begin  // an order was reduced in size
                market_event_next.kind   = MARKET_DATA_CANCEL;
                market_event_next.shares = in_data[8*MARKET_CANCEL_SHARES_OFFSET +: 32];
            end
            TYPE_DELETE: begin  // an order was removed: the ref is all it carries
                market_event_next.kind = MARKET_DATA_DELETE;
            end
            TYPE_REPLACE: begin  // an order became a new one (new ref, size, price; same side)
                market_event_next.kind          = MARKET_DATA_REPLACE;
                market_event_next.new_order_ref = in_data[8*MARKET_REPLACE_NEW_ORDER_REF_OFFSET +: 64];
                market_event_next.shares        = in_data[8*MARKET_REPLACE_SHARES_OFFSET +: 32];
                market_event_next.price         = in_data[8*MARKET_REPLACE_PRICE_OFFSET +: 64];
            end
            default: begin
                market_event_valid_next = 1'b0;  // unknown type: ignored
            end
        endcase
    end

    // Output registers: the event appears one cycle after the message.
    always_ff @(posedge clk) begin
        if (rst) begin
            market_event_valid <= 1'b0;
        end else begin
            market_event_valid <= market_event_valid_next;
        end
        // No reset: the event only matters when market_event_valid is high.
        market_event <= market_event_next;
    end

endmodule
