module FA_RUN_CTRL (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start_pulse,
    input  wire        soft_reset_pulse,
    input  wire        run_complete_pulse,
    input  wire        run_error_pulse,
    output wire        run_active,
    output wire        done_sticky,
    output wire        error_sticky,
    output wire [31:0] cycles
);

    reg run_active_r;
    reg done_sticky_r;
    reg error_sticky_r;
    reg [31:0] cycles_r;

    assign run_active = run_active_r;
    assign done_sticky = done_sticky_r;
    assign error_sticky = error_sticky_r;
    assign cycles = cycles_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            run_active_r <= 1'b0;
            done_sticky_r <= 1'b0;
            error_sticky_r <= 1'b0;
            cycles_r <= 32'd0;
        end else if (clear || soft_reset_pulse) begin
            run_active_r <= 1'b0;
            done_sticky_r <= 1'b0;
            error_sticky_r <= 1'b0;
            cycles_r <= 32'd0;
        end else begin
            if (start_pulse && !run_active_r) begin
                run_active_r <= 1'b1;
                done_sticky_r <= 1'b0;
                error_sticky_r <= 1'b0;
                cycles_r <= 32'd0;
            end else if (run_active_r) begin
                cycles_r <= cycles_r + 1'b1;
                if (run_complete_pulse) begin
                    run_active_r <= 1'b0;
                    done_sticky_r <= 1'b1;
                end else if (run_error_pulse) begin
                    run_active_r <= 1'b0;
                    error_sticky_r <= 1'b1;
                end
            end
        end
    end

endmodule
