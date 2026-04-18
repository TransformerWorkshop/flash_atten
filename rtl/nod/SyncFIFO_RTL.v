/*
    RTL synchronous FIFO
    Data width configurable
    FIFO depth configurable
    Can be configured as FWFT mode or standard mode
*/
module SyncFIFO_RTL #(
    parameter   width =                 32,
    parameter   depth =                 16,
    parameter   depth_LOG =             4,
    parameter   FWFT =                  1 //1:First Word Fall Through,0:Standard
)(
    input   wire                        clk_i,
    input   wire                        rst_i,

    input   wire                        read_i,
    input   wire                        write_i,
    output  reg                         full_o,
    output  reg                         empty_o,

    input   wire    [width-1 : 0]       data_i,
    output  wire    [width-1 : 0]       data_o
);

reg [width-1 : 0] data_o_std;
reg [width-1 : 0] mem [depth-1 : 0];
reg [depth_LOG-1 : 0] wp, rp;
reg w_flag, r_flag;

function [depth_LOG-1:0] ptr_trunc;
    input integer value;
    begin
        ptr_trunc = value[depth_LOG-1:0];
    end
endfunction

localparam [depth_LOG-1:0] LAST_PTR = ptr_trunc(depth - 1);

always@(posedge clk_i or posedge rst_i)
begin
    if(rst_i)
    begin
        wp <= 0;
        w_flag <= 0;
    end
    else if(~full_o & write_i)
    begin
        wp <= (wp==LAST_PTR) ? {depth_LOG{1'b0}} : (wp + 1'b1);
        w_flag <= (wp==LAST_PTR) ? ~w_flag : w_flag;
    end
end

always@(posedge clk_i)
begin
    if(write_i & ~full_o)
    begin
        mem[wp] <= data_i;
    end
end

always@(posedge clk_i or posedge rst_i)
begin
    if(rst_i)
    begin
        rp <= 0;
        r_flag <= 0;
    end
    else if(~empty_o & read_i)
    begin
        rp <= (rp==LAST_PTR) ? {depth_LOG{1'b0}} : (rp + 1'b1);
        r_flag <= (rp==LAST_PTR) ? ~r_flag : r_flag;
    end
end

always@(posedge clk_i or posedge rst_i)
begin
    if(rst_i) data_o_std <= 0;
    else
    begin
        if(~empty_o & read_i)
            data_o_std <= mem[rp];
    end
end

always@(*)
begin
    if(wp==rp)
    begin
        if(r_flag==w_flag)
        begin
            full_o = 0;
            empty_o = 1;
        end
        else
        begin
            full_o = 1;
            empty_o = 0;
        end
    end
    else
    begin
        full_o = 0;
        empty_o = 0;
    end
end

generate if(FWFT == 0) begin: FWFT_MODE
    assign data_o = data_o_std;
end else begin: STANDARD_MOD
    assign data_o = mem[rp];
end endgenerate

endmodule
