`ifndef             __PARAM_V__
`define             __PARAM_V__

// Processing Tile (PT) instruction definitions

`define             INST_WIDTH              32
`define             QUEUE_LEN               4
`define             PT_SIZE_W               10
`define             PT_LOCAL_ADDR_W         12
`define             PT_LOCAL_BUF_BIT        11
`define             PT_LOCAL_ELEM_H         10
`define             PT_LOCAL_ELEM_L         0

// PT opcode definitions
`define             PT_OP_MATMUL            4'h1
`define             PT_OP_QCFG              4'h2
`define             PT_OP_MATADD            4'h3
`define             PT_OP_LOAD              4'h4
`define             PT_OP_CFG               4'hf

// PT instruction fields for MATMUL opcode:
// [31:28] opcode
// [27:26] M scale
// [25:24] N scale
// [23:22] K scale
// [21:12] reserved A field (must be zero)
// [11: 2] reserved B field (must be zero)
// [ 1: 0] reserved
`define             PT_INST_OPCODE_H        31
`define             PT_INST_OPCODE_L        28
`define             PT_INST_M_H             27
`define             PT_INST_M_L             26
`define             PT_INST_N_H             25
`define             PT_INST_N_L             24
`define             PT_INST_K_H             23
`define             PT_INST_K_L             22
`define             PT_INST_A_OFF_H         21
`define             PT_INST_A_OFF_L         12
`define             PT_INST_B_OFF_H         11
`define             PT_INST_B_OFF_L         2

// PT LOAD fields:
// [31:28] opcode
// [27]    need_a
// [26]    need_b
// [25:16] A size in elements
// [15: 6] B size in elements
// [ 5: 0] reserved, must be zero
`define             PT_LOAD_NEED_A_BIT      27
`define             PT_LOAD_NEED_B_BIT      26
`define             PT_LOAD_A_SIZE_H        25
`define             PT_LOAD_A_SIZE_L        16
`define             PT_LOAD_B_SIZE_H        15
`define             PT_LOAD_B_SIZE_L        6
`define             PT_LOAD_RSV_H           5
`define             PT_LOAD_RSV_L           0

// PT MNK encoding
`define             PT_SCALE_SCALAR         2'b00
`define             PT_SCALE_FULL_DIV4      2'b01
`define             PT_SCALE_FULL_DIV2      2'b10
`define             PT_SCALE_FULL           2'b11

// PT CFG selector (used when opcode == PT_OP_CFG)
`define             PT_CFG_A_BASE_LO        4'h0
`define             PT_CFG_A_BASE_HI        4'h1
`define             PT_CFG_B_BASE_LO        4'h2
`define             PT_CFG_B_BASE_HI        4'h3

// PT QCFG header fields (used when opcode == PT_OP_QCFG and cmd == HDR)
`define             PT_QCFG_CMD_H           27
`define             PT_QCFG_CMD_L           24
`define             PT_QCFG_QTYPE_H         23
`define             PT_QCFG_QTYPE_L         22
`define             PT_QCFG_GRAN_H          21
`define             PT_QCFG_GRAN_L          19

`define             PT_QCFG_CMD_HDR         4'h0

`define             PT_QTYPE_SYMMETRIC      2'b00

`define             PT_QGRAN_PER_TENSOR     3'd0
`define             PT_QGRAN_X_WISE         3'd1
`define             PT_QGRAN_Y_WISE         3'd2
`define             PT_QGRAN_X_WISE_DIV2    3'd3
`define             PT_QGRAN_Y_WISE_DIV2    3'd4

// PT_DISPATCH <-> PT_MD mem command kinds
`define             PT_MEM_KIND_W           2
`define             PT_MEM_KIND_CFG         4'd0
`define             PT_MEM_KIND_QCFG_HDR    4'd1
`define             PT_MEM_KIND_QCFG_PAYLOAD 4'd2
`define             PT_MEM_KIND_REJECT      4'd3

// PT_DISPATCH <-> PT_MALLOC command kinds
`define             PT_MALLOC_KIND_W        2
`define             PT_MALLOC_KIND_LOAD     2'd0
`define             PT_MALLOC_KIND_MATMUL   2'd1
`define             PT_MALLOC_KIND_MATADD   2'd2

// Public DMA request kinds
`define             PT_DMA_KIND_W           3
`define             PT_DMA_KIND_A           3'b001
`define             PT_DMA_KIND_B           3'b010
`define             PT_DMA_KIND_C           3'b100

// Stream-side DMA kind tags
`define             PT_STREAM_KIND_A        2'b01
`define             PT_STREAM_KIND_B        2'b10
`define             PT_STREAM_KIND_C        2'b11

`endif
