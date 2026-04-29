# FA_P_BYPASS_REAL

RTL: [`rtl/fa_p_bypass_real.v`](../../../rtl/fa_p_bypass_real.v)

`FA_P_BYPASS_REAL` 从 row state 的 `p_tile_flat` 直接切片给 PV GEMM，替代独立 P SRAM。

```text
+--------------------------------------------------------------+
| FA_P_BYPASS_REAL                                             |
|                                                              |
| row_p_tile_flat[4095:0]                                      |
| 16 rows x 16 columns, packed as 32-bit words with two lanes   |
|        |                                                     |
|        v                                                     |
| +----------------------+                                     |
| | slice mux            | rd_addr selects one PV acc slice     |
| | for each row 0..15   | word index = row * 8 + rd_addr       |
| +----------+-----------+                                     |
|            |                                                |
|            v                                                |
| rd_data[511:0] -> FA_QK_PV_SHARED_CORE_REAL PV input A       |
| rd_valid follows rd_en by one clock                          |
+--------------------------------------------------------------+
```

映射：

```text
for row in 0..15:
  rd_data[row * 32 +: 32] =
      row_p_tile_flat[((row * 8 + rd_addr) * 32) +: 32]
```

意义：

| 项目 | 说明 |
|---|---|
| 面积 | 移除独立 P buffer/SRAM |
| 延迟 | P rows 由 row-state 输出直接旁路到 PV |
| 接口 | 保持 PV 侧 `rd_en/rd_addr/rd_valid/rd_data` 读接口 |
