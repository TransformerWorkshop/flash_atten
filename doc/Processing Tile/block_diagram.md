# PT Block Diagram

This page uses a plain symbol diagram for the current PT RTL rooted at [`rtl/pt.v`](../../rtl/pt.v) and [`rtl/pt_top_v2.v`](../../rtl/pt_top_v2.v).

It is intentionally architectural rather than pin-accurate. For exact signal widths and behavior, treat the RTL and the rest of this document set as authoritative.

## 1. Native PT Core

```text
ctrl_* 
  |
  v
+-------------+        md_cmd         +-----------+      dma_req_*      +-------------------+
| PT_DISPATCH | --------------------> |   PT_MD   | ------------------> | External Read DMA |
+------+------+                       | CFG/QCFG  |                     +---------+---------+
       | malloc_cmd                   | LOAD/EXP  | <-----------------------------+
       |                              +-----+-----+            s_axis_* load beats |
       |                                    |                                     |
       v                                    | A/B writes                           |
+-------------+     fill_req / done         | CSR writes                           |
| PT_MALLOC   | <-------------------------> |                                     |
| A/B cache   |                             v                                     |
| + alloc     |                        +---------+                                |
+------+------+                        |CSR_BANK | ---- quant cfg ---------------+|
       | ce_cmd + local bases + M buf  +---------+                               ||
       v                                                                        ||
+-------------+      A row      +---------+                                     ||
|   PT_CE     | <-------------- | A_BANK  | <-----------------------------------+|
| compute ctl |                 +---------+                                      |
+------+------+      B/C row    +---------+                                      |
       | <--------------------- | B_BANK  | <------------------------------------+
       |                        +----+----+
       |                             |
       | MATMUL                      | MATADD rhs
       v                             v
   +------+                      +-------+
   | GEMM | ---> +-------+ --->  | GEMA  |
   +------+      | QUANT |       +---+---+
                 +---+---+           ^
                     | quant rows     | retained M row
                     |                |
                     v                |
                +---------------------------+
                |          PT_M_MEM         |
                |   dual logical M buffers  |
                +-------------+-------------+
                              |
                              | export rows
                              v
                         +-----------+      m_dma_req_* / m_axis_*    +--------------------+
                         |   PT_MD   | ------------------------------> | External Write DMA |
                         +-----+-----+                                 +--------------------+
                               |
                               | md / malloc / ce responses + irq
                               v
                          +---------+
                          | RESPMUX |
                          +----+----+
                               |
                               v
                    ctrl_resp / ctrl_resp_valid / irq
```

## 2. Optional PT_DMA_TOP Wrapper

```text
Software / AXI-Lite
       |
       v
+------------------+      push / pop      +------------------------------+
| PT_DMA_AXIL_CSR  | <------------------> | cmd FIFO / resp FIFO / desc  |
+---------+--------+                      +---------------+--------------+
          |                                                |
          | staged commands / addresses                    | native PT ctrl_* + desc lookup
          |                                                v
          |                                        +---------------+
          +--------------------------------------> |    PT core    |
                                                   +-------+-------+
                                                           | rd_dma_desc_*
                                                           v
                                                   +---------------+
                                                   | Read DMA eng. |
                                                   +-------+-------+
                                                           |
                                                           | s_axis_*
                                                           v
                                                   +---------------+
                                                   |    PT core    |
                                                   +-------+-------+
                                                           | wr_dma_desc_* + m_axis_*
                                                           v
                                                   +---------------+
                                                   | Write DMA eng.|
                                                   +---------------+
```

## 3. Reading Notes

- `PT_DISPATCH` classifies ingress commands into memory/control traffic and compute/allocation traffic.
- `PT_MALLOC` tracks A/B residency by `ctrl_id`, decides whether fills are required, and only sends legal/resident work to `PT_CE`.
- `PT_MD` owns `CFG`, `QCFG`, `LOAD`, external A/B/C DMA fills, M-buffer export state, and automatic post-compute export.
- `PT_CE` runs `MATMUL` through `GEMM -> QUANT` and `MATADD` through `GEMA`, then writes final rows into `PT_M_MEM`.
- `PT_M_MEM` serves both retained-M reads for `MATADD` and export reads for `PT_MD`.
