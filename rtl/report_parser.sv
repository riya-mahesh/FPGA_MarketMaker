// This file was generated with the help of Claude Code.
//
// Execution report parser: decodes one whole execution report per valid
// cycle into a report_event_t.
//
// Timing: the event is registered, so report_event_valid is high exactly one
// cycle after in_valid. A new report may arrive every cycle. Reports of an
// unknown type are ignored (report_event_valid stays low).
module report_parser
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,

    // One whole report per valid cycle. Byte 0 (the type) is in bits [7:0];
    // bytes past the end of the report are zero. The sequence number,
    // timestamp, and fields the hot path doesn't use (instrument, time in
    // force, match number, liquidity, reasons) are deliberately not decoded.
    input  logic                    in_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [MESSAGE_BITS-1:0] in_data,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic                    report_event_valid,
    output report_event_t           report_event
);

    wire [7:0] message_type = in_data[7:0];

    logic          report_event_valid_next;
    report_event_t report_event_next;

    always_comb begin
        report_event_valid_next = in_valid;
        report_event_next       = '0;
        report_event_next.token = in_data[8*REPORT_TOKEN_OFFSET +: 64];

        case (message_type)
            TYPE_ACCEPTED: begin
                report_event_next.kind      = REPORT_ACCEPTED;
                report_event_next.is_buy    = in_data[8*REPORT_ACCEPTED_SIDE_OFFSET +: 8] == SIDE_BUY;
                report_event_next.shares    = in_data[8*REPORT_ACCEPTED_SHARES_OFFSET +: 32];
                report_event_next.price     = in_data[8*REPORT_ACCEPTED_PRICE_OFFSET +: 64];
                report_event_next.order_ref = in_data[8*REPORT_ACCEPTED_ORDER_REF_OFFSET +: 64];
            end
            TYPE_REPLACED: begin
                report_event_next.kind           = REPORT_REPLACED;
                report_event_next.previous_token = in_data[8*REPORT_REPLACED_PREVIOUS_TOKEN_OFFSET +: 64];
                report_event_next.is_buy         = in_data[8*REPORT_REPLACED_SIDE_OFFSET +: 8] == SIDE_BUY;
                report_event_next.shares         = in_data[8*REPORT_REPLACED_SHARES_OFFSET +: 32];
                report_event_next.price          = in_data[8*REPORT_REPLACED_PRICE_OFFSET +: 64];
                report_event_next.order_ref      = in_data[8*REPORT_REPLACED_ORDER_REF_OFFSET +: 64];
            end
            TYPE_EXECUTED: begin
                report_event_next.kind   = REPORT_EXECUTED;
                report_event_next.shares = in_data[8*REPORT_EXECUTED_SHARES_OFFSET +: 32];
                report_event_next.price  = in_data[8*REPORT_EXECUTED_PRICE_OFFSET +: 64];
            end
            TYPE_REJECTED: begin
                report_event_next.kind = REPORT_REJECTED;
            end
            TYPE_CANCELED: begin
                report_event_next.kind   = REPORT_CANCELED;
                report_event_next.shares = in_data[8*REPORT_CANCELED_SHARES_OFFSET +: 32];
            end
            default: begin
                report_event_valid_next = 1'b0;  // unknown type: ignored
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            report_event_valid <= 1'b0;
        end else begin
            report_event_valid <= report_event_valid_next;
        end
        // No reset: the event only matters when report_event_valid is high.
        report_event <= report_event_next;
    end

endmodule
