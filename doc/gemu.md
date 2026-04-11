# GEMU – Multiply-Accumulate Unit

`GEMU` 是 GEMM 阵列中的单个处理单元，负责对输入流 `a/b` 执行点积累加，并通过输出握手端口给出结果。

---

## 1 Hardware

### 1.1 功能概述

- 输入：`a`、`b` 两路标量流（`WIDTH` 位）。
- 控制：`start` 启动一次累加，`num_acc` 指定累加对数。
- 输出：`m`（`4*WIDTH` 位累加结果）和 `m_valid/m_ready` 握手。
- 内部通过 3 个 `sync_fifo` 做 A/B 输入缓冲与 M 输出缓冲。

### 1.2 参数

| Parameter | Default | Description |
| :-------- | :------ | :---------- |
| `WIDTH` | 32 | 输入数据位宽 |

### 1.3 接口

| Direction | Signal | Width | Description |
| :-------- | :----- | :---- | :---------- |
| in | `clk` | 1 | 时钟 |
| in | `rstn` | 1 | 低有效复位 |
| in | `clear` | 1 | 软复位 |
| in | `a` | `WIDTH` | A 输入 |
| in | `a_valid` | 1 | A 输入有效 |
| out | `a_ready` | 1 | A 输入就绪 |
| in | `b` | `WIDTH` | B 输入 |
| in | `b_valid` | 1 | B 输入有效 |
| out | `b_ready` | 1 | B 输入就绪 |
| out | `m` | `4*WIDTH` | 累加结果 |
| out | `m_valid` | 1 | 结果有效 |
| in | `m_ready` | 1 | 下游就绪 |
| in | `start` | 1 | 启动一次计算 |
| in | `num_acc` | `WIDTH` | 累加次数 |

### 1.4 状态机

- `STATE_IDLE`：等待 `start`。
- `STATE_ACCM`：按握手接收 A/B，对 `(a*b)` 累加，直到 `acc_cnt == num_acc`。

关键实现语义：
- `acc_done = (acc_cnt == num_acc)`。
- 输出/输入握手被约束在累加状态：
  - `fifo_m_valid = in_accm && acc_done`
  - `fifo_a_ready = in_accm && !acc_done`
  - `fifo_b_ready = in_accm && !acc_done`

这保证了未进入 `STATE_ACCM` 时不会错误地产生历史输出。

### 1.5 WaveDrom 时序

#### 1) 正常计算（`num_acc = 3`）

```wavedrom
{
  "signal": [
    {"name":"clk",      "wave":"p..........."},
    {"name":"start",    "wave":"01.........."},
    {"name":"state",    "wave":"3.5.....3...", "data":["IDLE","ACCM","IDLE"]},
    {"name":"a_valid",  "wave":"0.11110....."},
    {"name":"a_ready",  "wave":"0.11110....."},
    {"name":"b_valid",  "wave":"0.11110....."},
    {"name":"b_ready",  "wave":"0.11110....."},
    {"name":"acc_cnt",  "wave":"x...2222x...", "data":["0","1","2","3"]},
    {"name":"m_valid",  "wave":"0......10..."},
    {"name":"m_ready",  "wave":"1..........."},
    {"name":"m",        "wave":"x......=x...", "data":["sum"]}
  ]
}
```

#### 2) 输出回压（`m_ready` 拉低）

```wavedrom
{
  "signal": [
    {"name":"clk",      "wave":"p........."},
    {"name":"m_valid",  "wave":"0....1...."},
    {"name":"m_ready",  "wave":"1....0.1.."},
    {"name":"m",        "wave":"x....=.=..", "data":["sum","sum"]}
  ]
}
```

说明：`m_valid=1` 期间，若 `m_ready=0`，输出 FIFO 保持数据不变，直到握手完成。

---

## 2 Verification Notes

- `tb/tb_gemu.v` 覆盖场景：
  - 基本点积
  - 宽位累加
  - A/B 任一侧延迟或双侧延迟
- 关键检查点：
  - 仅在累加完成后输出一次有效结果
  - 输出可被 `m_ready` 正确回压
