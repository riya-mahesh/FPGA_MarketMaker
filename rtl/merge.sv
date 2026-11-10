// This file was generated with the help of Claude Code.
//
// Merge: combines market data items (from the sequence check) and execution
// reports (from the report parser) into one ordered stream of pipeline items,
// so every later stage sees both kinds in a single, well-defined order.
//
// Items leave at most once every two cycles: some later stages (the book)
// take two cycles per item, so this is the pipeline's initiation interval.
// When both kinds of item are waiting, market data goes first (it is what
// tick-to-trade latency is measured on). Anything that can't leave yet waits
// in a one-entry buffer for its stream, and each stream's items leave in the
// order they arrived.
//
// Why one entry per stream is enough: neither stream can deliver a message
// every cycle. The shortest message is 26 bytes (a Rejected report) and a
// 64-bit network link carries 8 bytes per cycle, so each stream delivers at
// most one message every 4 cycles: at most 2 items per 4 cycles in total,
// which is exactly what the merge can send. A waiting item therefore always
// leaves before the next item of its stream arrives. If that assumption is
// ever broken, overflow goes high and stays high (an item was dropped).
//
// Timing: a registered stage. An item leaves one cycle after it arrives if
// nothing is ahead of it, later otherwise.
module merge
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

    // Sticky: an item arrived while its stream's buffer was full, and was lost.
    output logic           overflow
);

    // Registers: a one-entry buffer per stream, the output, the overflow.
    logic           market_buffer_valid, market_buffer_valid_next;
    pipeline_item_t market_buffer, market_buffer_next;
    logic           report_buffer_valid, report_buffer_valid_next;
    report_event_t  report_buffer, report_buffer_next;
    logic           item_valid_next;
    pipeline_item_t item_next;
    logic           overflow_next;

    // Wraps a report in a pipeline item.
    function automatic pipeline_item_t report_item(report_event_t report);
        pipeline_item_t wrapped;
        wrapped              = '0;
        wrapped.source       = SOURCE_REPORT;
        wrapped.report_event = report;
        return wrapped;
    endfunction

    // An item left on the last clock edge: wait one cycle before the next.
    wire can_send = !item_valid;

    // The oldest waiting item of each stream: the buffered one, else a new one.
    wire            market_waiting = market_buffer_valid || market_item_valid;
    wire            report_waiting = report_buffer_valid || report_event_valid;
    pipeline_item_t oldest_market;
    report_event_t  oldest_report;
    assign oldest_market = market_buffer_valid ? market_buffer : market_item;
    assign oldest_report = report_buffer_valid ? report_buffer : report_event;

    // What leaves this cycle: market data first.
    wire send_market = can_send && market_waiting;
    wire send_report = can_send && !market_waiting && report_waiting;

    always_comb begin
        item_valid_next = send_market || send_report;
        item_next       = send_market ? oldest_market : report_item(oldest_report);
        overflow_next   = overflow;

        // Market buffer: refilled by a new item if the buffered one just left;
        // otherwise a new item that didn't leave waits here.
        market_buffer_valid_next = market_buffer_valid;
        market_buffer_next       = market_buffer;
        if (send_market && market_buffer_valid) begin
            market_buffer_valid_next = market_item_valid;
            market_buffer_next       = market_item;
        end else if (send_market) begin
            market_buffer_valid_next = 1'b0;
        end else if (market_item_valid && market_buffer_valid) begin
            overflow_next = 1'b1;  // nowhere to put it
        end else if (market_item_valid) begin
            market_buffer_valid_next = 1'b1;
            market_buffer_next       = market_item;
        end

        // Report buffer: the same rules.
        report_buffer_valid_next = report_buffer_valid;
        report_buffer_next       = report_buffer;
        if (send_report && report_buffer_valid) begin
            report_buffer_valid_next = report_event_valid;
            report_buffer_next       = report_event;
        end else if (send_report) begin
            report_buffer_valid_next = 1'b0;
        end else if (report_event_valid && report_buffer_valid) begin
            overflow_next = 1'b1;  // nowhere to put it
        end else if (report_event_valid) begin
            report_buffer_valid_next = 1'b1;
            report_buffer_next       = report_event;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            market_buffer_valid <= 1'b0;
            report_buffer_valid <= 1'b0;
            item_valid          <= 1'b0;
            overflow            <= 1'b0;
        end else begin
            market_buffer_valid <= market_buffer_valid_next;
            report_buffer_valid <= report_buffer_valid_next;
            item_valid          <= item_valid_next;
            overflow            <= overflow_next;
        end
        // No reset: these only matter when the matching valid bit is high.
        market_buffer <= market_buffer_next;
        report_buffer <= report_buffer_next;
        item          <= item_next;
    end

endmodule
