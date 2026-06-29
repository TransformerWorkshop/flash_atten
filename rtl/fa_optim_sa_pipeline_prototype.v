module FA_OPTIM_SA_PIPELINE_PROTOTYPE #(
    parameter integer TILE_COUNT = 136,
    parameter integer CLUSTER_COUNT = 4,
    parameter integer MAX_INFLIGHT_TILES = 32,
    parameter integer QK_FEED_CYCLES = 16,
    parameter integer QK_CYCLES = 16,
    parameter integer PV_FEED_CYCLES = 0,
    parameter integer PV_CYCLES = 32,
    parameter integer OACC_CYCLES = 16,
    parameter integer ROW_UPDATE_CYCLES = 1
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    output wire        busy,
    output wire        done,
    output reg  [31:0] cycles,
    output reg  [31:0] sa_busy_cycles,
    output reg  [31:0] feeder_busy_cycles,
    output reg  [31:0] row_state_busy_cycles,
    output reg  [31:0] qk_task_count,
    output reg  [31:0] pv_task_count,
    output reg  [31:0] oacc_task_count,
    output reg  [31:0] row_update_task_count,
    output reg  [31:0] qk_feed_count,
    output reg  [31:0] pv_feed_count,
    output reg  [31:0] cluster_wait_task_count,
    output reg  [31:0] feeder_wait_slot_count,
    output reg  [31:0] pv_wait_row_update_count,
    output reg  [31:0] active0_count,
    output reg  [31:0] active1_count,
    output reg  [31:0] active2_count,
    output reg  [31:0] active3_count,
    output reg  [31:0] active4_count,
    output wire [63:0] buffer_probe_data
);

    localparam integer SRAM_BANK_COUNT = 21;

    localparam [1:0] TASK_IDLE = 2'd0;
    localparam [1:0] TASK_QK   = 2'd1;
    localparam [1:0] TASK_PV   = 2'd2;
    localparam [1:0] TASK_OACC = 2'd3;

    reg        running_r;
    reg        running_n;
    reg        done_r;
    reg        done_n;

    reg [31:0] cycles_n;
    reg [31:0] sa_busy_cycles_n;
    reg [31:0] feeder_busy_cycles_n;
    reg [31:0] row_state_busy_cycles_n;
    reg [31:0] qk_task_count_n;
    reg [31:0] pv_task_count_n;
    reg [31:0] oacc_task_count_n;
    reg [31:0] row_update_task_count_n;
    reg [31:0] qk_feed_count_n;
    reg [31:0] pv_feed_count_n;
    reg [31:0] cluster_wait_task_count_n;
    reg [31:0] feeder_wait_slot_count_n;
    reg [31:0] pv_wait_row_update_count_n;
    reg [31:0] active0_count_n;
    reg [31:0] active1_count_n;
    reg [31:0] active2_count_n;
    reg [31:0] active3_count_n;
    reg [31:0] active4_count_n;

    reg [31:0] next_tile_count_r;
    reg [31:0] next_tile_count_n;
    reg [31:0] done_tile_count_r;
    reg [31:0] done_tile_count_n;
    reg [31:0] inflight_tile_count_r;
    reg [31:0] inflight_tile_count_n;
    reg [31:0] qk_ready_count_r;
    reg [31:0] qk_ready_count_n;
    reg [31:0] row_wait_count_r;
    reg [31:0] row_wait_count_n;
    reg [31:0] pv_ready_count_r;
    reg [31:0] pv_ready_count_n;
    reg [31:0] pv_feed_wait_count_r;
    reg [31:0] pv_feed_wait_count_n;
    reg [31:0] oacc_ready_count_r;
    reg [31:0] oacc_ready_count_n;

    reg [1:0]  feeder_kind_r;
    reg [1:0]  feeder_kind_n;
    reg [15:0] feeder_remaining_r;
    reg [15:0] feeder_remaining_n;
    reg [15:0] row_state_remaining_r;
    reg [15:0] row_state_remaining_n;

    reg [1:0]  cluster_kind_r [0:CLUSTER_COUNT-1];
    reg [1:0]  cluster_kind_n [0:CLUSTER_COUNT-1];
    reg [15:0] cluster_remaining_r [0:CLUSTER_COUNT-1];
    reg [15:0] cluster_remaining_n [0:CLUSTER_COUNT-1];

    integer ci;
    integer active_cluster_count_i;

    assign busy = running_r;
    assign done = done_r;

    always @(*) begin
        running_n = running_r;
        done_n = done_r;

        cycles_n = cycles;
        sa_busy_cycles_n = sa_busy_cycles;
        feeder_busy_cycles_n = feeder_busy_cycles;
        row_state_busy_cycles_n = row_state_busy_cycles;
        qk_task_count_n = qk_task_count;
        pv_task_count_n = pv_task_count;
        oacc_task_count_n = oacc_task_count;
        row_update_task_count_n = row_update_task_count;
        qk_feed_count_n = qk_feed_count;
        pv_feed_count_n = pv_feed_count;
        cluster_wait_task_count_n = cluster_wait_task_count;
        feeder_wait_slot_count_n = feeder_wait_slot_count;
        pv_wait_row_update_count_n = pv_wait_row_update_count;
        active0_count_n = active0_count;
        active1_count_n = active1_count;
        active2_count_n = active2_count;
        active3_count_n = active3_count;
        active4_count_n = active4_count;

        next_tile_count_n = next_tile_count_r;
        done_tile_count_n = done_tile_count_r;
        inflight_tile_count_n = inflight_tile_count_r;
        qk_ready_count_n = qk_ready_count_r;
        row_wait_count_n = row_wait_count_r;
        pv_ready_count_n = pv_ready_count_r;
        pv_feed_wait_count_n = pv_feed_wait_count_r;
        oacc_ready_count_n = oacc_ready_count_r;
        feeder_kind_n = feeder_kind_r;
        feeder_remaining_n = feeder_remaining_r;
        row_state_remaining_n = row_state_remaining_r;

        for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
            cluster_kind_n[ci] = cluster_kind_r[ci];
            cluster_remaining_n[ci] = cluster_remaining_r[ci];
        end
        active_cluster_count_i = 0;

        if (start) begin
            running_n = 1'b1;
            done_n = 1'b0;

            cycles_n = 32'd0;
            sa_busy_cycles_n = 32'd0;
            feeder_busy_cycles_n = 32'd0;
            row_state_busy_cycles_n = 32'd0;
            qk_task_count_n = 32'd0;
            pv_task_count_n = 32'd0;
            oacc_task_count_n = 32'd0;
            row_update_task_count_n = 32'd0;
            qk_feed_count_n = 32'd0;
            pv_feed_count_n = 32'd0;
            cluster_wait_task_count_n = 32'd0;
            feeder_wait_slot_count_n = 32'd0;
            pv_wait_row_update_count_n = 32'd0;
            active0_count_n = 32'd0;
            active1_count_n = 32'd0;
            active2_count_n = 32'd0;
            active3_count_n = 32'd0;
            active4_count_n = 32'd0;

            next_tile_count_n = 32'd0;
            done_tile_count_n = 32'd0;
            inflight_tile_count_n = 32'd0;
            qk_ready_count_n = 32'd0;
            row_wait_count_n = 32'd0;
            pv_ready_count_n = 32'd0;
            pv_feed_wait_count_n = 32'd0;
            oacc_ready_count_n = 32'd0;
            feeder_kind_n = TASK_IDLE;
            feeder_remaining_n = 16'd0;
            row_state_remaining_n = 16'd0;
            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                cluster_kind_n[ci] = TASK_IDLE;
                cluster_remaining_n[ci] = 16'd0;
            end
        end else if (running_r) begin
            active_cluster_count_i = 0;
            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                if (cluster_remaining_r[ci] != 16'd0) begin
                    active_cluster_count_i = active_cluster_count_i + 1;
                end
            end

            cycles_n = cycles + 32'd1;
            sa_busy_cycles_n = sa_busy_cycles + active_cluster_count_i;
            if (feeder_remaining_r != 16'd0) begin
                feeder_busy_cycles_n = feeder_busy_cycles + 32'd1;
            end
            if (row_state_remaining_r != 16'd0) begin
                row_state_busy_cycles_n = row_state_busy_cycles + 32'd1;
            end
            case (active_cluster_count_i)
                0: active0_count_n = active0_count + 32'd1;
                1: active1_count_n = active1_count + 32'd1;
                2: active2_count_n = active2_count + 32'd1;
                3: active3_count_n = active3_count + 32'd1;
                default: active4_count_n = active4_count + 32'd1;
            endcase

            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                if (cluster_remaining_r[ci] != 16'd0) begin
                    cluster_remaining_n[ci] = cluster_remaining_r[ci] - 16'd1;
                    if (cluster_remaining_r[ci] == 16'd1) begin
                        if (cluster_kind_r[ci] == TASK_QK) begin
                            if (ROW_UPDATE_CYCLES > 0) begin
                                row_wait_count_n = row_wait_count_n + 32'd1;
                            end else if (PV_CYCLES > 0) begin
                                if (PV_FEED_CYCLES > 0) begin
                                    pv_feed_wait_count_n = pv_feed_wait_count_n + 32'd1;
                                    pv_wait_row_update_count_n = pv_wait_row_update_count_n + 32'd1;
                                end else begin
                                    pv_ready_count_n = pv_ready_count_n + 32'd1;
                                end
                            end else if (OACC_CYCLES > 0) begin
                                oacc_ready_count_n = oacc_ready_count_n + 32'd1;
                            end else begin
                                done_tile_count_n = done_tile_count_n + 32'd1;
                                inflight_tile_count_n = inflight_tile_count_n - 32'd1;
                            end
                        end else if (cluster_kind_r[ci] == TASK_PV) begin
                            if (OACC_CYCLES > 0) begin
                                oacc_ready_count_n = oacc_ready_count_n + 32'd1;
                            end else begin
                                done_tile_count_n = done_tile_count_n + 32'd1;
                                inflight_tile_count_n = inflight_tile_count_n - 32'd1;
                            end
                        end else if (cluster_kind_r[ci] == TASK_OACC) begin
                            done_tile_count_n = done_tile_count_n + 32'd1;
                            inflight_tile_count_n = inflight_tile_count_n - 32'd1;
                        end
                        cluster_kind_n[ci] = TASK_IDLE;
                    end
                end
            end

            if (feeder_remaining_r != 16'd0) begin
                feeder_remaining_n = feeder_remaining_r - 16'd1;
                if (feeder_remaining_r == 16'd1) begin
                    if (feeder_kind_r == TASK_QK) begin
                        qk_ready_count_n = qk_ready_count_n + 32'd1;
                    end else if (feeder_kind_r == TASK_PV) begin
                        pv_ready_count_n = pv_ready_count_n + 32'd1;
                    end
                    feeder_kind_n = TASK_IDLE;
                end
            end

            if (row_state_remaining_r != 16'd0) begin
                row_state_remaining_n = row_state_remaining_r - 16'd1;
                if (row_state_remaining_r == 16'd1) begin
                    row_update_task_count_n = row_update_task_count_n + 32'd1;
                    if (PV_CYCLES > 0) begin
                        if (PV_FEED_CYCLES > 0) begin
                            pv_feed_wait_count_n = pv_feed_wait_count_n + 32'd1;
                            pv_wait_row_update_count_n = pv_wait_row_update_count_n + 32'd1;
                        end else begin
                            pv_ready_count_n = pv_ready_count_n + 32'd1;
                        end
                    end else if (OACC_CYCLES > 0) begin
                        oacc_ready_count_n = oacc_ready_count_n + 32'd1;
                    end else begin
                        done_tile_count_n = done_tile_count_n + 32'd1;
                        inflight_tile_count_n = inflight_tile_count_n - 32'd1;
                    end
                end
            end

            if ((ROW_UPDATE_CYCLES > 0) && (row_state_remaining_n == 16'd0) && (row_wait_count_n != 32'd0)) begin
                row_wait_count_n = row_wait_count_n - 32'd1;
                row_state_remaining_n = ROW_UPDATE_CYCLES;
            end

            if (feeder_remaining_n == 16'd0) begin
                if ((PV_FEED_CYCLES > 0) && (pv_feed_wait_count_n != 32'd0)) begin
                    pv_feed_wait_count_n = pv_feed_wait_count_n - 32'd1;
                    feeder_kind_n = TASK_PV;
                    feeder_remaining_n = PV_FEED_CYCLES;
                    pv_feed_count_n = pv_feed_count_n + 32'd1;
                end else if ((next_tile_count_n < TILE_COUNT) && (inflight_tile_count_n < MAX_INFLIGHT_TILES)) begin
                    next_tile_count_n = next_tile_count_n + 32'd1;
                    inflight_tile_count_n = inflight_tile_count_n + 32'd1;
                    feeder_kind_n = TASK_QK;
                    feeder_remaining_n = QK_FEED_CYCLES;
                    qk_feed_count_n = qk_feed_count_n + 32'd1;
                end else begin
                    feeder_wait_slot_count_n = feeder_wait_slot_count_n + 32'd1;
                end
            end

            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                if (cluster_remaining_n[ci] == 16'd0) begin
                    if ((oacc_ready_count_n != 32'd0) && (OACC_CYCLES > 0)) begin
                        oacc_ready_count_n = oacc_ready_count_n - 32'd1;
                        cluster_kind_n[ci] = TASK_OACC;
                        cluster_remaining_n[ci] = OACC_CYCLES;
                        oacc_task_count_n = oacc_task_count_n + 32'd1;
                    end else if ((pv_ready_count_n != 32'd0) && (PV_CYCLES > 0)) begin
                        pv_ready_count_n = pv_ready_count_n - 32'd1;
                        cluster_kind_n[ci] = TASK_PV;
                        cluster_remaining_n[ci] = PV_CYCLES;
                        pv_task_count_n = pv_task_count_n + 32'd1;
                    end else if (qk_ready_count_n != 32'd0) begin
                        qk_ready_count_n = qk_ready_count_n - 32'd1;
                        cluster_kind_n[ci] = TASK_QK;
                        cluster_remaining_n[ci] = QK_CYCLES;
                        qk_task_count_n = qk_task_count_n + 32'd1;
                    end else begin
                        cluster_wait_task_count_n = cluster_wait_task_count_n + 32'd1;
                    end
                end
            end

            if (done_tile_count_n >= TILE_COUNT) begin
                running_n = 1'b0;
                done_n = 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            running_r <= 1'b0;
            done_r <= 1'b0;
            cycles <= 32'd0;
            sa_busy_cycles <= 32'd0;
            feeder_busy_cycles <= 32'd0;
            row_state_busy_cycles <= 32'd0;
            qk_task_count <= 32'd0;
            pv_task_count <= 32'd0;
            oacc_task_count <= 32'd0;
            row_update_task_count <= 32'd0;
            qk_feed_count <= 32'd0;
            pv_feed_count <= 32'd0;
            cluster_wait_task_count <= 32'd0;
            feeder_wait_slot_count <= 32'd0;
            pv_wait_row_update_count <= 32'd0;
            active0_count <= 32'd0;
            active1_count <= 32'd0;
            active2_count <= 32'd0;
            active3_count <= 32'd0;
            active4_count <= 32'd0;
            next_tile_count_r <= 32'd0;
            done_tile_count_r <= 32'd0;
            inflight_tile_count_r <= 32'd0;
            qk_ready_count_r <= 32'd0;
            row_wait_count_r <= 32'd0;
            pv_ready_count_r <= 32'd0;
            pv_feed_wait_count_r <= 32'd0;
            oacc_ready_count_r <= 32'd0;
            feeder_kind_r <= TASK_IDLE;
            feeder_remaining_r <= 16'd0;
            row_state_remaining_r <= 16'd0;
            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                cluster_kind_r[ci] <= TASK_IDLE;
                cluster_remaining_r[ci] <= 16'd0;
            end
        end else if (clear) begin
            running_r <= 1'b0;
            done_r <= 1'b0;
            cycles <= 32'd0;
            sa_busy_cycles <= 32'd0;
            feeder_busy_cycles <= 32'd0;
            row_state_busy_cycles <= 32'd0;
            qk_task_count <= 32'd0;
            pv_task_count <= 32'd0;
            oacc_task_count <= 32'd0;
            row_update_task_count <= 32'd0;
            qk_feed_count <= 32'd0;
            pv_feed_count <= 32'd0;
            cluster_wait_task_count <= 32'd0;
            feeder_wait_slot_count <= 32'd0;
            pv_wait_row_update_count <= 32'd0;
            active0_count <= 32'd0;
            active1_count <= 32'd0;
            active2_count <= 32'd0;
            active3_count <= 32'd0;
            active4_count <= 32'd0;
            next_tile_count_r <= 32'd0;
            done_tile_count_r <= 32'd0;
            inflight_tile_count_r <= 32'd0;
            qk_ready_count_r <= 32'd0;
            row_wait_count_r <= 32'd0;
            pv_ready_count_r <= 32'd0;
            pv_feed_wait_count_r <= 32'd0;
            oacc_ready_count_r <= 32'd0;
            feeder_kind_r <= TASK_IDLE;
            feeder_remaining_r <= 16'd0;
            row_state_remaining_r <= 16'd0;
            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                cluster_kind_r[ci] <= TASK_IDLE;
                cluster_remaining_r[ci] <= 16'd0;
            end
        end else begin
            running_r <= running_n;
            done_r <= done_n;
            cycles <= cycles_n;
            sa_busy_cycles <= sa_busy_cycles_n;
            feeder_busy_cycles <= feeder_busy_cycles_n;
            row_state_busy_cycles <= row_state_busy_cycles_n;
            qk_task_count <= qk_task_count_n;
            pv_task_count <= pv_task_count_n;
            oacc_task_count <= oacc_task_count_n;
            row_update_task_count <= row_update_task_count_n;
            qk_feed_count <= qk_feed_count_n;
            pv_feed_count <= pv_feed_count_n;
            cluster_wait_task_count <= cluster_wait_task_count_n;
            feeder_wait_slot_count <= feeder_wait_slot_count_n;
            pv_wait_row_update_count <= pv_wait_row_update_count_n;
            active0_count <= active0_count_n;
            active1_count <= active1_count_n;
            active2_count <= active2_count_n;
            active3_count <= active3_count_n;
            active4_count <= active4_count_n;
            next_tile_count_r <= next_tile_count_n;
            done_tile_count_r <= done_tile_count_n;
            inflight_tile_count_r <= inflight_tile_count_n;
            qk_ready_count_r <= qk_ready_count_n;
            row_wait_count_r <= row_wait_count_n;
            pv_ready_count_r <= pv_ready_count_n;
            pv_feed_wait_count_r <= pv_feed_wait_count_n;
            oacc_ready_count_r <= oacc_ready_count_n;
            feeder_kind_r <= feeder_kind_n;
            feeder_remaining_r <= feeder_remaining_n;
            row_state_remaining_r <= row_state_remaining_n;
            for (ci = 0; ci < CLUSTER_COUNT; ci = ci + 1) begin
                cluster_kind_r[ci] <= cluster_kind_n[ci];
                cluster_remaining_r[ci] <= cluster_remaining_n[ci];
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (TILE_COUNT <= 0) begin
            $fatal(1, "FA_OPTIM_SA_PIPELINE_PROTOTYPE TILE_COUNT must be positive");
        end
        if (CLUSTER_COUNT != 4) begin
            $fatal(1, "FA_OPTIM_SA_PIPELINE_PROTOTYPE smoke model currently exposes four cluster histogram bins");
        end
        if ((QK_FEED_CYCLES <= 0) || (QK_CYCLES <= 0)) begin
            $fatal(1, "FA_OPTIM_SA_PIPELINE_PROTOTYPE requires positive QK feed/compute cycles");
        end
    end
`endif

    wire [63:0] sram_rd_data_w [0:SRAM_BANK_COUNT-1];
    wire [63:0] probe_chain_w [0:SRAM_BANK_COUNT];

    assign probe_chain_w[0] = 64'd0;

    genvar bank_gi;
    generate
        for (bank_gi = 0; bank_gi < SRAM_BANK_COUNT; bank_gi = bank_gi + 1) begin : gen_local_sram_banks
            localparam [4:0] BANK_IDX = bank_gi;
            wire        bank_wr_en_w = running_r && (cycles[4:0] == BANK_IDX);
            wire        bank_rd_en_w = running_r && !bank_wr_en_w;
            wire [63:0] bank_wr_data_w = {cycles, next_tile_count_r} ^ {59'd0, BANK_IDX};

            FA_LOCAL_TILE_SRAM_16X64X16 u_bank (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .wr_en(bank_wr_en_w),
                .wr_row_idx(cycles[7:4]),
                .wr_chunk_idx(cycles[3:0]),
                .wr_data(bank_wr_data_w),
                .wr_mask(64'hffff_ffff_ffff_ffff),
                .rd_en(bank_rd_en_w),
                .rd_row_idx(cycles[7:4]),
                .rd_chunk_idx(cycles[3:0]),
                .rd_valid(),
                .rd_data(sram_rd_data_w[bank_gi])
            );

            assign probe_chain_w[bank_gi + 1] = probe_chain_w[bank_gi] ^ sram_rd_data_w[bank_gi];
        end
    endgenerate

    assign buffer_probe_data = probe_chain_w[SRAM_BANK_COUNT];

endmodule
