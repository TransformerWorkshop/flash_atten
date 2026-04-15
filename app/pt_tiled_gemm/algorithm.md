# 算法说明

## 1. 问题模型

这套 app 现在支持更一般的 tiled GEMM：

- `A = M x K`
- `B = K x N`
- `C = M x N`

但因为当前 PT 的 primitive 固定为 `16x16x16`，所以输入必须满足：

- `M % 16 == 0`
- `K % 16 == 0`
- `N % 16 == 0`

## 2. 指令编码与 Tile 分解

底层 `MATMUL` 指令现在把 `M/N/K` 三个字段解释为 raw tile count：

- `m_tiles = inst[27:24]`
- `n_tiles = inst[23:20]`
- `k_tiles = inst[19:16]`

当前这条扩展路径聚焦 K 方向累加：

- `m_tiles = 1`
- `n_tiles = 1`
- `k_tiles = 2` 或 `4`

同时保留 `k_tiles = 1` 的单-tile 兼容路径，方便已有基础测试继续工作。

对 app 的问题分解来说，仍然定义：

- `M_tiles = M / 16`
- `K_tiles = K / 16`
- `N_tiles = N / 16`

则完整问题会被拆成：

```text
partial_matmuls = M_tiles * K_tiles * N_tiles
```

每个 partial GEMM 都是：

```text
16x16 * 16x16 -> 16x16
```

对某个输出 tile `C[m_i, n_j]`，其计算公式为：

```text
C[m_i, n_j] = Σ_t A[m_i, k_t] * B[k_t, n_j]
```

其中 `t = 0 .. K_tiles-1`。

## 3. per_tensor Scale

默认量化配置固定为：

- `QCFG(per_tensor)`
- `inv_scale = 0x0001_0000`

在 app 的验证输入中，我们选用小的非负整数，保证：

- partial result 在 `32-bit` 内不溢出
- host reduction 与 `MATADD` reduction 都能与 software golden 一致

## 4. 三条候选算法

### 4.1 `host_reduce_direct_tiled_matmul`

流程：

1. `CFG A/B base`
2. `QCFG(per_tensor)`
3. 对每个输出 tile、每个 K tile 执行 `MATMUL`
4. host 对该输出 tile 的所有 partial result 做精确累加

优点：

- 最接近当前 RTL 的原生能力
- 不引入 `LOAD` 额外控制开销
- 不引入 `MATADD` 额外 export/归约链

### 4.2 `host_reduce_load_then_matmul`

流程：

1. `CFG A/B base`
2. `QCFG(per_tensor)`
3. 对每个 partial 先 `LOAD(A_tile, B_tile)`，再 `MATMUL`
4. host 做精确累加

特点：

- 更显式地表达 residency
- 但通常比 direct path 多出 `LOAD` 控制开销

### 4.3 `pt_matadd_reduce`

流程：

1. 对某个输出 tile，先计算第一个 partial GEMM
2. 再计算下一个 partial GEMM
3. 通过 `MATADD` 把“当前 partial”与“之前的 partial/sum”合并
4. 重复直到该输出 tile 的全部 K tiles 完成

特点：

- 归约逻辑更多留在 PT 侧
- 但会增加：
  - `MATADD` 次数
  - external C tile 回喂
  - export 次数

## 5. Unsupported Path

app 保留一个反例：

- `same_id_k_slice_swap`

含义是：

- 在同一个输出 tile 上
- 使用同一个 `ctrl_id`
- 试图把 `A/B` 从当前 K-slice 原地换到下一个 K-slice

当前 RTL 下这条路径不可靠，因为：

- A/B residency 是 `cache-by-id`
- 不换 `ctrl_id` 时，不会形成预期的新 A/B reload

如果当前问题的 `K_tiles < 2`，这条实验路径会自动被标记为：

- `not_applicable`
