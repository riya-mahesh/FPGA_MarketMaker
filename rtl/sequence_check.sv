// This file was generated with the help of Claude Code.
//
// Sequence check: the first pipeline stage. Wraps each decoded market data
// event in a pipeline_item_t and sets errors.sequence_gap if a feed message
// was missed.
//
// The feed numbers its messages 1, 2, 3, ... A message whose number isn't the
// expected one means at least one message was missed (or arrived twice). A gap
// is a standing error: errors.sequence_gap is set on the message that reveals
// it and on every message after it, until reset. After each message, the
// expected number becomes that message's number plus one.
//
// The event itself always passes through unchanged: this stage only flags the
// gap, and the quote manager decides what to do about it.
//
// Timing: a registered stage, so item_valid is high exactly one cycle after
// market_event_valid. A new event may arrive every cycle.
module sequence_check
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic               clk,
    input  logic               rst,

    /* verilator lint_off UNUSEDSIGNAL */  // from the stub; harmless now both are used
    input  logic               market_event_valid,  // a decoded event is on market_event
    input  market_data_event_t market_event,        // from the parser
    /* verilator lint_on UNUSEDSIGNAL */

    output logic               item_valid,          // item is real this cycle
    output pipeline_item_t     item                 // the event wrapped for the pipeline, gap flag set
);

    // Computed this cycle, registered on the next edge.
    logic           item_valid_next;
    pipeline_item_t item_next;

    // Sequence state, kept between messages.
    logic [63:0]    expected_sequence, expected_sequence_next;  // the number the next message should carry
    logic           gap_seen, gap_seen_next;                    // a gap was found on an earlier message

    always_comb begin
        logic gap;  // a gap at or before this message (a temporary, not a register)

        // Gap check: only real messages are checked (idle cycles carry junk); sticky once seen.
        gap = gap_seen
           || (market_event_valid && market_event.sequence_number != expected_sequence);

        // State update: idle cycles hold it; after a message, expect its number + 1 (resyncs after a gap).
        expected_sequence_next = expected_sequence;
        gap_seen_next          = gap_seen;
        if (market_event_valid) begin
            expected_sequence_next = market_event.sequence_number + 64'd1;
            gap_seen_next          = gap;
        end

        // Output: the event passes through unchanged, wrapped with the gap flag.
        item_valid_next               = market_event_valid;
        item_next                     = '0;
        item_next.source              = SOURCE_MARKET_DATA;  // not a report
        item_next.market_event        = market_event;
        item_next.errors.sequence_gap = gap;
    end

    // Registers: output (one cycle of latency) and sequence state.
    always_ff @(posedge clk) begin
        if (rst) begin
            item_valid        <= 1'b0;
            expected_sequence <= 64'd1;  // the feed starts at 1
            gap_seen          <= 1'b0;
        end else begin
            item_valid        <= item_valid_next;
            expected_sequence <= expected_sequence_next;
            gap_seen          <= gap_seen_next;
        end
        // No reset: the item only matters when item_valid is high.
        item <= item_next;
    end

endmodule
