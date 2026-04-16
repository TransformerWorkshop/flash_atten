module demux #(
    parameter DATA_WIDTH = 32
)(
    input  [DATA_WIDTH-1:0] data,
    input                   wr_en,
    input  [1:0]            mode,//0->fifo1, 1->fifo2, 2->fifo1&fifo2
    output [DATA_WIDTH-1:0] data_to_fifo1,
    output [DATA_WIDTH-1:0] data_to_fifo2,
    output                  wr_en_to_fifo1,
    output                  wr_en_to_fifo2
);

assign data_to_fifo1  = mode[1]  ? {{20{data[12]}},data[11:0]}   : data;//10 11特殊处理，00 01为data
assign data_to_fifo2  = mode[1]  ? {{20{data[28]}},data[27:16]}  : data;
assign wr_en_to_fifo1 = (mode==1)? 0 : wr_en;//00 10 11为wr_en
assign wr_en_to_fifo2 = (mode==0)? 0 : wr_en;//01 10 11为wr_en
endmodule