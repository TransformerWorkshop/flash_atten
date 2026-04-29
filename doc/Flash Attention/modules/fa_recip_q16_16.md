# FA_RECIP_Q16_16

RTL: [`rtl/fa_recip_q16_16.v`](../../../rtl/fa_recip_q16_16.v)

`FA_RECIP_Q16_16` 为 row-state online softmax 提供 `1 / l_new` 的 Q16.16 reciprocal 近似。

```text
+--------------------------------------------------------------+
| FA_RECIP_Q16_16                                              |
|                                                              |
| req_valid, in_value Q16.16                                   |
|        |                                                     |
|        v                                                     |
| +------------------+                                         |
| | divider comb     | dividend = 0x1_0000_0000                |
| | guard invalid    | divisor = in_value                      |
| +--------+---------+                                         |
|          | quotient_w                                        |
|          v                                                   |
| +------------------+                                         |
| | one-cycle hold   | pending_r, quotient_r                   |
| +--------+---------+                                         |
|          |                                                   |
|          v                                                   |
| resp_valid, out_value Q16.16, done_pulse                     |
+--------------------------------------------------------------+
```

行为：

| 输入情况 | 输出 |
|---|---|
| `in_value <= 0` | `0` |
| quotient > `0x7fffffff` | saturate to `0x7fffffff` |
| normal positive input | `0x1_0000_0000 / in_value` |

握手：

```text
req_ready = !pending_r && !resp_valid
req fire  -> latch quotient, pending_r=1
next clk  -> resp_valid=1
resp fire -> done_pulse=1
```
