// Network Interface (NI) for NOD
// Sits between Processing Element (PE) and router LOCAL port.
// TX path: packetizes PE data into HEAD + BODY + TAIL flits
// RX path: depacketizes received flits, delivers payload to PE
`include "param.vh"

// NoC Parameters:
/*
    RTID_H/L: bits in HEAD flit that carry the RTID (router ID) of the destination

    SCID_H/L: bits in HEAD flit that carry the SCID (source cluster/network-on-die ID)
    DCID_H/L: bits in HEAD flit that carry the DCID (destination cluster/network-on-die ID)

    SRID_H/L: bits in HEAD flit that carry the SRID (source router ID)
    DRID_H/L: bits in HEAD flit that carry the DRID (destination router ID)
*/


module network_interface #(
    parameter ROUTER_X = 0,
    parameter ROUTER_Y = 0
)(
    input  wire                 clk,
    input  wire                 rstn,

    // ---- PE TX Interface (PE -> NI -> NoC) ----
    input  wire [2:0]           tx_dest_x,
    input  wire [2:0]           tx_dest_y,
    input  wire [3:0]           tx_scid,
    input  wire [3:0]           tx_dcid,
    input  wire [127:0]         tx_data,
    input  wire                 tx_valid,
    output reg                  tx_ready,
    input  wire                 tx_start,       // first payload word of new packet
    input  wire                 tx_last,        // last payload word of packet

    // ---- PE RX Interface (NoC -> NI -> PE) ----
    output reg  [2:0]           rx_src_x,
    output reg  [2:0]           rx_src_y,
    output wire [127:0]         rx_data,
    output wire                 rx_valid,
    input  wire                 rx_ready,
    output wire                 rx_sop,         // first body flit of packet
    output wire                 rx_eop,         // last body flit (TAIL follows)

    // ---- NoC Inject Interface (NI -> Router LOCAL input) ----
    output wire [`DATA_WIDTH-1:0] noc_inj_data,
    output wire                 noc_inj_valid,
    input  wire                 noc_inj_ready,

    // ---- NoC Eject Interface (Router LOCAL output -> NI) ----
    input  wire [`DATA_WIDTH-1:0] noc_ejt_data,
    input  wire                 noc_ejt_valid,
    output wire                 noc_ejt_ready
);

// =========================================================================
// TX Path — Packetization (PE -> NoC)
// =========================================================================

localparam TX_IDLE = 2'd0;
localparam TX_HEAD = 2'd1;
localparam TX_BODY = 2'd2;
localparam TX_TAIL = 2'd3;

reg [1:0] tx_state, tx_nxt_state;
reg [2:0] tx_dest_x_r, tx_dest_y_r;
reg [3:0] tx_scid_r, tx_dcid_r;

// State register
always @(posedge clk or negedge rstn) begin
    if (!rstn)
        tx_state <= TX_IDLE;
    else
        tx_state <= tx_nxt_state;
end

// Latch destination on tx_start
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        tx_dest_x_r <= 3'd0;
        tx_dest_y_r <= 3'd0;
        tx_scid_r   <= 4'd0;
        tx_dcid_r   <= 4'd0;
    end else if (tx_state == TX_IDLE && tx_valid && tx_start) begin
        tx_dest_x_r <= tx_dest_x;
        tx_dest_y_r <= tx_dest_y;
        tx_scid_r   <= tx_scid;
        tx_dcid_r   <= tx_dcid;
    end
end

// Next-state logic
always @(*) begin
    tx_nxt_state = tx_state;
    case (tx_state)
        TX_IDLE: begin
            if (tx_valid && tx_start)
                tx_nxt_state = TX_HEAD;
            else
                tx_nxt_state = TX_IDLE;
        end
        TX_HEAD: begin
            if (noc_inj_ready)
                tx_nxt_state = TX_BODY;
        end
        TX_BODY: begin
            if (tx_valid && noc_inj_ready && tx_last)
                tx_nxt_state = TX_TAIL;
        end
        TX_TAIL: begin
            if (noc_inj_ready)
                tx_nxt_state = TX_IDLE;
        end
    endcase
end

// HEAD flit construction (matches cibd_transaction::pack format)
wire [129:0] head_flit;
assign head_flit = {2'b00,                               // [129:128] HEAD type
                    102'd0,                              // [127:26]  unused
                    tx_dest_x_r, tx_dest_y_r,            // [25:20]   RTID
                    tx_scid_r,                           // [19:16]   SCID
                    tx_dcid_r,                           // [15:12]   DCID
                    ROUTER_X[2:0], ROUTER_Y[2:0],        // [11:6]    SRID
                    tx_dest_x_r, tx_dest_y_r};           // [5:0]     DRID

// BODY flit construction
wire [129:0] body_flit;
assign body_flit = {`BODY, tx_data};

// TAIL flit construction
wire [129:0] tail_flit;
assign tail_flit = {`TAIL, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF};

// TX output mux
reg [`DATA_WIDTH-1:0] tx_flit;
reg                   tx_flit_valid;

always @(*) begin
    tx_flit       = {`DATA_WIDTH{1'b0}};
    tx_flit_valid = 1'b0;
    tx_ready      = 1'b0;
    case (tx_state)
        TX_IDLE: begin
            tx_ready = 1'b0;  // not consuming PE data yet
        end
        TX_HEAD: begin
            tx_flit       = head_flit;
            tx_flit_valid = 1'b1;
            tx_ready      = 1'b0;
        end
        TX_BODY: begin
            tx_flit       = body_flit;
            tx_flit_valid = tx_valid;
            tx_ready      = noc_inj_ready; // consum PE data when NoC ready
        end
        TX_TAIL: begin
            tx_flit       = tail_flit;
            tx_flit_valid = 1'b1;
            tx_ready      = 1'b0; // stop PE data transfer
        end
    endcase
end

assign noc_inj_data  = tx_flit;
assign noc_inj_valid = tx_flit_valid;


// =========================================================================
// RX Path — Depacketization (NoC -> PE)
// =========================================================================

localparam RX_IDLE = 2'd0;
localparam RX_DATA = 2'd1;

reg [1:0] rx_state, rx_nxt_state;
reg       rx_first_body;

wire [1:0] ejt_type = noc_ejt_data[129:128];

// State register
always @(posedge clk or negedge rstn) begin
    if (!rstn)
        rx_state <= RX_IDLE;
    else
        rx_state <= rx_nxt_state;
end

// First-body flag
always @(posedge clk or negedge rstn) begin
    if (!rstn)
        rx_first_body <= 1'b0;
    else if (rx_state == RX_IDLE && noc_ejt_valid && ejt_type == `HEAD)
        rx_first_body <= 1'b1;
    else if (rx_state == RX_DATA && noc_ejt_valid && ejt_type == `BODY && rx_ready)
        rx_first_body <= 1'b0;
end

// Latch source info from HEAD flit
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        rx_src_x <= 3'd0;
        rx_src_y <= 3'd0;
    end else if (rx_state == RX_IDLE && noc_ejt_valid && ejt_type == `HEAD) begin
        rx_src_x <= noc_ejt_data[11:9];   // SRID_X
        rx_src_y <= noc_ejt_data[8:6];    // SRID_Y
    end
end

// Next-state logic
always @(*) begin
    rx_nxt_state = rx_state;
    case (rx_state)
        RX_IDLE: begin
            if (noc_ejt_valid && ejt_type == `HEAD)
                rx_nxt_state = RX_DATA;
        end
        RX_DATA: begin
            if (noc_ejt_valid && ejt_type == `TAIL)
                rx_nxt_state = RX_IDLE;
        end
    endcase
end

// RX outputs
wire rx_is_body = (rx_state == RX_DATA) && noc_ejt_valid && (ejt_type == `BODY);
wire rx_is_tail = (rx_state == RX_DATA) && noc_ejt_valid && (ejt_type == `TAIL);

assign rx_data  = noc_ejt_data[127:0];
assign rx_valid = rx_is_body;
assign rx_sop   = rx_is_body && rx_first_body;
assign rx_eop   = rx_is_tail;

// Accept HEAD immediately; accept BODY when PE ready; accept TAIL immediately
assign noc_ejt_ready = (rx_state == RX_IDLE) ? 1'b1 :
                        rx_is_body            ? rx_ready :
                        rx_is_tail            ? 1'b1 :
                                                1'b1;

endmodule
