module sdp_ram #(
    parameter RAM_DATA_WIDTH = 32,
    parameter RAM_ADDR_WIDTH = 6
) (
    input  wire                            clk      ,
    
    input  wire                            wr_en    ,
    input  wire [    RAM_ADDR_WIDTH-1 : 0] wr_addr  ,
    input  wire [    RAM_DATA_WIDTH-1 : 0] wr_data  ,
    input  wire [(RAM_DATA_WIDTH/8)-1 : 0] wr_strb  ,

    input  wire                            rd_en    ,
    input  wire [    RAM_ADDR_WIDTH-1 : 0] rd_addr  ,
    output reg  [    RAM_DATA_WIDTH-1 : 0] rd_data   
);

    reg  [RAM_DATA_WIDTH-1 : 0] mem [0 : (1<<RAM_ADDR_WIDTH)-1];

    // write data to memory
    wire [RAM_DATA_WIDTH-1 : 0] wr_strb_data;

    genvar i;
    generate
        for (i = 0; i < (RAM_DATA_WIDTH / 8); i = i + 1) begin : wstrb
            assign wr_strb_data[8*i+:8] = (wr_strb[i]) ? wr_data[8*i+:8] : mem[wr_addr][8*i+:8];
        end
    endgenerate

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_strb_data;
        end
    end

    // read data from memory
    always @(posedge clk) begin
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule
