// This file was generated with the help of Claude Code.
//
// Register bank: the CPU's only way into the FPGA, and its window onto the
// pipeline's state. In a real system this sits behind PCIe: the CPU's
// stores to a memory-mapped address become writes here, and its loads become
// reads. Here, the C++ cold path drives the same bus directly.
//
// Writes (CPU to FPGA): the credit, recomputed from volatility on every
// timer tick, and the halt flag, set when the loss limit is breached. Writes
// to read-only or unknown addresses are ignored.
//
// Reads (FPGA to CPU): our position and realized cash, and the mid of the
// current book, so the CPU can compute volatility and profit and loss (the
// book lives here, not on the CPU). Reads are combinational (the data is
// valid in the same cycle as the address); an unknown address reads as zero.
//
// The mid comes with a valid bit, clear while the book is invalid (a side
// empty, or crossed); the mid bits mean nothing then.
//
// The data bus is 64 bits wide, so every value arrives in a single write: no
// value is ever seen half-updated.
module register_bank
    import config_pkg::*;
(
    input  logic                             clk,
    input  logic                             rst,

    // Write port.
    input  logic                             write_valid,
    input  logic [REGISTER_ADDRESS_BITS-1:0] write_address,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      write_data,     // only the low bits of each register are used
    /* verilator lint_on UNUSEDSIGNAL */

    // Read port.
    input  logic [REGISTER_ADDRESS_BITS-1:0] read_address,
    output logic [63:0]                      read_data,

    // Values the CPU writes, for the pipeline.
    output logic [31:0]                      credit,
    output logic                             halt,

    // Values the CPU reads, from the quote manager.
    input  logic signed [31:0]               position,
    input  logic signed [63:0]               cash,

    // The top of book after each item, from the book.
    input  logic                             book_update_valid,
    input  logic                             book_valid,
    input  logic [31:0]                      bid_price,
    input  logic [31:0]                      ask_price
);

    logic [31:0] credit_next;
    logic        halt_next;
    logic        mid_valid, mid_valid_next;
    logic [31:0] mid, mid_next;

    always_comb begin
        credit_next = credit;
        halt_next   = halt;
        if (write_valid) begin
            case (write_address)
                REGISTER_CREDIT: credit_next = write_data[31:0];
                REGISTER_HALT:   halt_next   = write_data != '0;
                default: begin
                    // Read-only or unknown: ignored.
                end
            endcase
        end

        mid_valid_next = mid_valid;
        mid_next       = mid;
        if (book_update_valid) begin
            mid_valid_next = book_valid;
            mid_next       = 32'(({1'b0, bid_price} + {1'b0, ask_price}) >> 1);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            credit    <= MIN_CREDIT;
            halt      <= 1'b0;
            mid_valid <= 1'b0;
        end else begin
            credit    <= credit_next;
            halt      <= halt_next;
            mid_valid <= mid_valid_next;
        end
        // No reset: the mid only matters when mid_valid says so.
        mid <= mid_next;
    end

    always_comb begin
        case (read_address)
            REGISTER_CREDIT:   read_data = {32'd0, credit};
            REGISTER_HALT:     read_data = {63'd0, halt};
            REGISTER_POSITION: read_data = {{32{position[31]}}, position};
            REGISTER_CASH:     read_data = cash;
            REGISTER_MID:      read_data = {mid_valid, 31'd0, mid};
            default:           read_data = '0;
        endcase
    end

endmodule
