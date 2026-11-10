// This file was generated with the help of Claude Code.
//
// Quote manager: owns our two quotes (one bid, one offer) and decides, after
// every item, whether to enter or replace them; tracks our orders through
// the exchange's reports; and cancels everything when told to halt.
//
// For each item:
//
//   1. If the item is a report, apply it: an Accepted or Replaced makes the
//      side's in-flight request a live order; an Executed changes our
//      position and cash and the order's open shares; a Rejected or Canceled
//      clears the request or order it names.
//   2. Decide (decide_side, once per side): halt on any sticky error or the
//      CPU's halt register. Otherwise, if pricing says we can quote, each side
//      with no request in flight that the position limit allows gets a new
//      order (if it has none) or a replacement (if its price is no longer the
//      desired one), always of QUOTE_SHARES.
//   3. Send the requests, assigning tokens in order (1, 2, 3, ...).
//
// Both sides may need an order on the same item, but the order encoder takes
// one request per cycle. Items arrive at least two cycles apart (the merge
// guarantees it), so the bid's request leaves in the item's first cycle and
// the ask's in the second.
//
// A halt is sticky. Once halted, nothing is quoted again, and a small state
// machine cancels everything we have at the exchange: each side's resting
// order and any request still in flight, one cancel per cycle. Reports keep
// updating our position and cash, which the CPU reads to compute profit and
// loss.
//
// Timing: a request leaves one cycle after the item that caused it (the
// ask's, if both sides send, two cycles after).
module quote_manager
    import config_pkg::*;
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic               clk,
    input  logic               rst,

    // At most one item every two cycles.
    input  logic               in_item_valid,
    input  quote_item_t        in_item,

    // From the register bank: the CPU wants us to stop (the loss limit).
    input  logic               halt_request,

    // To the order encoder.
    output logic               request_valid,
    output order_request_t     request,

    // To the register bank, for the CPU.
    output logic signed [31:0] position,  // shares, positive = long
    output logic signed [63:0] cash       // price units x shares
);

    // One side's quote at the exchange.
    typedef struct packed {
        logic        live;           // a resting order exists
        logic [63:0] token;          // the resting order's token
        logic [31:0] price;
        logic [31:0] open_shares;
        logic        pending;        // a request is in flight
        logic [63:0] pending_token;  // the in-flight request's token
    } quote_t;

    // Everything the reports change.
    typedef struct packed {
        quote_t             bid;
        quote_t             ask;
        logic signed [31:0] position;
        logic signed [63:0] cash;
    } order_state_t;

    // Applies one execution report to our order state.
    /* verilator lint_off UNUSEDSIGNAL */  // the report's order reference and previous token
    function automatic order_state_t apply_report(order_state_t state, report_event_t report);
    /* verilator lint_on UNUSEDSIGNAL */
        order_state_t updated;
        logic         bid_live, ask_live, bid_pending, ask_pending;
        logic [63:0]  value;  // shares x price of a fill

        updated     = state;
        bid_live    = state.bid.live && state.bid.token == report.token;
        ask_live    = state.ask.live && state.ask.token == report.token;
        bid_pending = state.bid.pending && state.bid.pending_token == report.token;
        ask_pending = state.ask.pending && state.ask.pending_token == report.token;
        value       = {32'd0, report.shares} * {32'd0, report.price[31:0]};

        case (report.kind)
            REPORT_ACCEPTED, REPORT_REPLACED: begin
                // The in-flight request is now the side's resting order.
                if (report.is_buy && bid_pending) begin
                    updated.bid.live        = 1'b1;
                    updated.bid.token       = report.token;
                    updated.bid.price       = report.price[31:0];
                    updated.bid.open_shares = report.shares;
                    updated.bid.pending     = 1'b0;
                end
                if (!report.is_buy && ask_pending) begin
                    updated.ask.live        = 1'b1;
                    updated.ask.token       = report.token;
                    updated.ask.price       = report.price[31:0];
                    updated.ask.open_shares = report.shares;
                    updated.ask.pending     = 1'b0;
                end
            end
            REPORT_EXECUTED: begin
                // A fill: buying adds to our position and spends cash.
                if (bid_live || bid_pending) begin
                    updated.position = state.position + $signed(report.shares);
                    updated.cash     = state.cash - $signed(value);
                end else if (ask_live || ask_pending) begin
                    updated.position = state.position - $signed(report.shares);
                    updated.cash     = state.cash + $signed(value);
                end
                if (bid_live) begin
                    updated.bid.open_shares = state.bid.open_shares - report.shares;
                    updated.bid.live        = state.bid.open_shares != report.shares;
                end
                if (ask_live) begin
                    updated.ask.open_shares = state.ask.open_shares - report.shares;
                    updated.ask.live        = state.ask.open_shares != report.shares;
                end
            end
            REPORT_REJECTED: begin
                // A rejected replace means the order was already gone.
                if (bid_pending) updated.bid.pending = 1'b0;
                if (ask_pending) updated.ask.pending = 1'b0;
            end
            REPORT_CANCELED: begin
                if (bid_live)    updated.bid.live    = 1'b0;
                if (bid_pending) updated.bid.pending = 1'b0;
                if (ask_live)    updated.ask.live    = 1'b0;
                if (ask_pending) updated.ask.pending = 1'b0;
            end
            default: begin
            end
        endcase
        return updated;
    endfunction

    // Whether one side needs an order, and if so, the request.
    typedef struct packed {
        logic           send;
        order_request_t request;
    } side_decision_t;

    /* verilator lint_off UNUSEDSIGNAL */  // the quote's open shares and in-flight token
    function automatic side_decision_t decide_side(quote_t quote, logic is_buy, logic can_quote,
                                                   logic [31:0] desired_price,
                                                   logic signed [31:0] current_position,
                                                   logic [63:0] token);
    /* verilator lint_on UNUSEDSIGNAL */
        side_decision_t     decision;
        logic signed [33:0] after_fill;  // our position if this order filled completely
        logic               blocked;

        after_fill = is_buy ? 34'(current_position) + $signed({2'b00, QUOTE_SHARES})
                            : 34'(current_position) - $signed({2'b00, QUOTE_SHARES});
        blocked    = is_buy ? after_fill >  $signed({2'b00, POSITION_LIMIT})
                            : after_fill < -$signed({2'b00, POSITION_LIMIT});

        decision.send    = can_quote && !blocked && !quote.pending
                        && (!quote.live || quote.price != desired_price);
        decision.request = '0;
        decision.request.token  = token;
        decision.request.shares = QUOTE_SHARES;
        decision.request.price  = {32'd0, desired_price};
        if (quote.live) begin
            decision.request.kind           = ORDER_REPLACE;
            decision.request.existing_token = quote.token;
        end else begin
            decision.request.kind   = ORDER_ENTER;
            decision.request.is_buy = is_buy;
        end
        return decision;
    endfunction

    // The cancel-all state machine: one state per thing to cancel.
    typedef enum logic [2:0] {
        CANCEL_IDLE,
        CANCEL_BID_ORDER,    // the bid's resting order
        CANCEL_BID_REQUEST,  // the bid's in-flight request
        CANCEL_ASK_ORDER,
        CANCEL_ASK_REQUEST,
        CANCEL_DONE
    } cancel_state_e;

    // What cancel-all cancels, captured when it starts.
    typedef struct packed {
        logic        bid_order_valid;
        logic [63:0] bid_order_token;
        logic        bid_request_valid;
        logic [63:0] bid_request_token;
        logic        ask_order_valid;
        logic [63:0] ask_order_token;
        logic        ask_request_valid;
        logic [63:0] ask_request_token;
    } cancel_list_t;

    function automatic order_request_t cancel_request(logic [63:0] token);
        order_request_t cancel;
        cancel        = '0;
        cancel.kind   = ORDER_CANCEL;
        cancel.token  = token;
        cancel.shares = '0;  // reduce to 0: cancel entirely
        return cancel;
    endfunction

    // ---------------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------------
    order_state_t   state, state_next;
    logic [63:0]    next_token, next_token_next;
    logic           halted, halted_next;
    logic           second_valid, second_valid_next;  // the ask's request, due next cycle
    order_request_t second_request, second_request_next;
    cancel_state_e  cancel_state, cancel_state_next;
    cancel_list_t   cancel_list, cancel_list_next;
    logic           request_valid_next;
    order_request_t request_next;

    always_comb begin
        order_state_t   after_report;  // the order state after this item's report
        logic           halt;          // halted as of this cycle
        logic           quoting;       // this cycle carries an item we quote on
        side_decision_t bid_decision, ask_decision;
        logic [63:0]    ask_token;
        logic           cancel_due;    // the current cancel state has something to cancel
        logic [63:0]    cancel_token;

        // 1. Apply the report.
        after_report = state;
        if (in_item_valid && in_item.source == SOURCE_REPORT) begin
            after_report = apply_report(state, in_item.report_event);
        end

        // 2. Decide.
        halt = halted || halt_request
            || (in_item_valid && (in_item.errors.sequence_gap || in_item.errors.unknown_order
                                  || in_item.errors.book_overflow));
        quoting = in_item_valid && !halt;

        bid_decision = decide_side(after_report.bid, 1'b1, in_item.can_quote, in_item.bid_price,
                                   after_report.position, next_token);
        ask_token    = bid_decision.send ? next_token + 64'd1 : next_token;
        ask_decision = decide_side(after_report.ask, 1'b0, in_item.can_quote, in_item.ask_price,
                                   after_report.position, ask_token);
        if (!quoting) begin
            bid_decision.send = 1'b0;
            ask_decision.send = 1'b0;
        end

        // 3. Record the requests, and send them: the bid's now, the ask's now
        //    if the bid has nothing, otherwise next cycle.
        state_next = after_report;
        if (bid_decision.send) begin
            state_next.bid.pending       = 1'b1;
            state_next.bid.pending_token = bid_decision.request.token;
        end
        if (ask_decision.send) begin
            state_next.ask.pending       = 1'b1;
            state_next.ask.pending_token = ask_decision.request.token;
        end
        next_token_next = next_token + 64'(bid_decision.send) + 64'(ask_decision.send);
        halted_next     = halt;

        // Cancel-all: started once halted, when nothing else is waiting to go.
        cancel_state_next = cancel_state;
        cancel_list_next  = cancel_list;
        cancel_due        = 1'b0;
        cancel_token      = '0;
        case (cancel_state)
            CANCEL_IDLE: begin
                if (halted && !second_valid) begin
                    cancel_list_next.bid_order_valid   = state.bid.live;
                    cancel_list_next.bid_order_token   = state.bid.token;
                    cancel_list_next.bid_request_valid = state.bid.pending;
                    cancel_list_next.bid_request_token = state.bid.pending_token;
                    cancel_list_next.ask_order_valid   = state.ask.live;
                    cancel_list_next.ask_order_token   = state.ask.token;
                    cancel_list_next.ask_request_valid = state.ask.pending;
                    cancel_list_next.ask_request_token = state.ask.pending_token;
                    cancel_state_next                  = CANCEL_BID_ORDER;
                end
            end
            CANCEL_BID_ORDER: begin
                cancel_due        = cancel_list.bid_order_valid;
                cancel_token      = cancel_list.bid_order_token;
                cancel_state_next = CANCEL_BID_REQUEST;
            end
            CANCEL_BID_REQUEST: begin
                cancel_due        = cancel_list.bid_request_valid;
                cancel_token      = cancel_list.bid_request_token;
                cancel_state_next = CANCEL_ASK_ORDER;
            end
            CANCEL_ASK_ORDER: begin
                cancel_due        = cancel_list.ask_order_valid;
                cancel_token      = cancel_list.ask_order_token;
                cancel_state_next = CANCEL_ASK_REQUEST;
            end
            CANCEL_ASK_REQUEST: begin
                cancel_due        = cancel_list.ask_request_valid;
                cancel_token      = cancel_list.ask_request_token;
                cancel_state_next = CANCEL_DONE;
            end
            default: begin
                // CANCEL_DONE: stays here until reset.
            end
        endcase

        // The request port, in priority order: last item's second request,
        // then cancel-all, then this item's first request.
        request_valid_next  = 1'b0;
        request_next        = '0;
        second_valid_next   = 1'b0;
        second_request_next = second_request;
        if (second_valid) begin
            request_valid_next = 1'b1;
            request_next       = second_request;
        end else if (cancel_due) begin
            request_valid_next = 1'b1;
            request_next       = cancel_request(cancel_token);
        end else if (bid_decision.send) begin
            request_valid_next  = 1'b1;
            request_next        = bid_decision.request;
            second_valid_next   = ask_decision.send;
            second_request_next = ask_decision.request;
        end else if (ask_decision.send) begin
            request_valid_next = 1'b1;
            request_next       = ask_decision.request;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= '0;
            next_token    <= 64'd1;
            halted        <= 1'b0;
            second_valid  <= 1'b0;
            cancel_state  <= CANCEL_IDLE;
            request_valid <= 1'b0;
        end else begin
            state         <= state_next;
            next_token    <= next_token_next;
            halted        <= halted_next;
            second_valid  <= second_valid_next;
            cancel_state  <= cancel_state_next;
            request_valid <= request_valid_next;
        end
        // No reset: these only matter when second_valid / the cancel state /
        // request_valid says so.
        second_request <= second_request_next;
        cancel_list    <= cancel_list_next;
        request        <= request_next;
    end

    assign position = state.position;
    assign cash     = state.cash;

endmodule
