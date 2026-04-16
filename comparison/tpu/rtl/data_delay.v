module data_delay #(
    parameter DATA_WIDTH   = 32 ,
    parameter DELAY_STAGES = 8  
) (
    input  wire                  clk      ,
    input  wire                  rst_n    ,
    input  wire                  en       ,
    input  wire [DATA_WIDTH-1:0] data_in  ,
    output wire [DATA_WIDTH-1:0] data_out
);

    generate
        if (DELAY_STAGES == 0) begin : no_delay

            assign data_out = data_in;

        end else begin : with_delay

            reg     [DATA_WIDTH-1:0] delay_reg[DELAY_STAGES-1:0];
            integer                  i;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (i = 0; i < DELAY_STAGES; i = i + 1) begin
                        delay_reg[i] <= {DATA_WIDTH{1'b0}};
                    end
                end else if (en) begin  // 只在使能有效时更新延迟链
                    delay_reg[0] <= data_in;
                    for (i = 1; i < DELAY_STAGES; i = i + 1) begin
                        delay_reg[i] <= delay_reg[i-1];
                    end
                end
            end

            assign data_out = delay_reg[DELAY_STAGES-1];

        end
    endgenerate

endmodule