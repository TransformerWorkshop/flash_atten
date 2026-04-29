# FA_QK_PV_STREAM_CTRL

RTL: [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v)

`FA_QK_PV_STREAM_CTRL` owns the shared core stream FSM. It tracks the active mode, row block, PV column block, read issue count, and GEMM feed count. It also turns downstream block backpressure into GEMM output ready and stops issuing new reads while a completed block is waiting to be consumed.

```text
+--------------------------------------------------------------------------------+
| FA_QK_PV_STREAM_CTRL                                                           |
|                                                                                |
| qk_req_fire / pv_req_fire                                                       |
|        |                                                                       |
|        v                                                                       |
| +----------------------+                                                       |
| | mode latch           | MODE_QK or MODE_PV                                    |
| | row_blk, col_blk     | QK: row only; PV: row and 4 column sub-blocks         |
| +----------+-----------+                                                       |
|            |                                                                   |
|            v                                                                   |
| +----------------------+       +-------------------------------------------+   |
| | read issue counter   |------>| Q/K or P/V read enables and addresses     |   |
| | feed counter         |       | q/k addr 0..31, p addr 0..7, v {col,addr} |   |
| +----------+-----------+       +-------------------------------------------+   |
|            |                                                                   |
|            v                                                                   |
| +----------------------+                                                       |
| | GEMM handshake       | start on first feed, num_acc by mode                 |
| | backpressure gate    | hold when block_valid && !block_ready               |
| +----------+-----------+                                                       |
|            |                                                                   |
|            v                                                                   |
| gemm_start, gemm_feed_fire, gemm_output_ready, gemm_stream_fire                |
+--------------------------------------------------------------------------------+
```

FSM:

```text
ST_IDLE
  -- qk_req_fire --> MODE_QK, row_blk=0, col_blk=0, ST_STREAM
  -- pv_req_fire --> MODE_PV, row_blk=0, col_blk=0, ST_STREAM

ST_STREAM
  issue source reads while no output block is pending
  feed GEMM when both operands and GEMM input are ready
  after last feed -> ST_COLLECT

ST_COLLECT
  wait for GEMM output groups
  QK: advance row_blk after each 4x16 block
  PV: advance col_blk 0..3, then row_blk
  final block -> ST_IDLE
```

Mode constants:

```text
MODE_QK: num_acc=32, read Q/K addresses 0..31
MODE_PV: num_acc=8, read P addresses 0..7 and V addresses {col_blk, addr}
```
