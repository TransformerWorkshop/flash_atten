module FA_RECIP_Q16_16 (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  in_value,
    output reg          resp_valid,
    input  wire         resp_ready,
    output reg  [31:0]  out_value,
    output reg          done_pulse
);

    reg        busy_r;
    reg [5:0]  countdown_r;
    reg [31:0] quotient_r;
    reg [63:0] dividend_w;
    reg [63:0] divisor_w;
    reg [63:0] quotient_w;

    assign req_ready = !busy_r && !resp_valid;

    always @(*) begin
        dividend_w = 64'h1_0000_0000;
        divisor_w = {32'd0, in_value};
        if ((in_value[31] == 1'b1) || (in_value == 32'd0)) begin
            quotient_w = 64'd0;
        end else begin
            quotient_w = dividend_w / divisor_w;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            countdown_r <= 6'd0;
            quotient_r <= 32'd0;
            resp_valid <= 1'b0;
            out_value <= 32'd0;
            done_pulse <= 1'b0;
        end else if (clear) begin
            busy_r <= 1'b0;
            countdown_r <= 6'd0;
            quotient_r <= 32'd0;
            resp_valid <= 1'b0;
            out_value <= 32'd0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (busy_r) begin
                if (countdown_r == 6'd0) begin
                    busy_r <= 1'b0;
                    resp_valid <= 1'b1;
                    out_value <= quotient_r;
                end else begin
                    countdown_r <= countdown_r - 1'b1;
                end
            end else if (req_valid && req_ready) begin
                if (quotient_w > 64'h7FFF_FFFF) begin
                    quotient_r <= 32'h7FFF_FFFF;
                end else begin
                    quotient_r <= quotient_w[31:0];
                end
                busy_r <= 1'b1;
                countdown_r <= 6'd31;
            end
        end
    end

endmodule
