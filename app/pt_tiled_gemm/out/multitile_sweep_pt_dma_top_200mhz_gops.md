# PT_DMA_TOP Multitile Throughput at 200MHz

Source sweep:

- [`multitile_sweep_pt_dma_top_icarus.json`](/tmp/flash_atten_codex_app/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus.json)

Assumptions:

- target: `PT_DMA_TOP`
- simulator: `icarus`
- frequency for absolute throughput: `200MHz`
- conversion: `GOPS = ops/cycle * 0.2`

## Result Table

| M | N | K | done cycles | ops/cycle | GOPS @200MHz | note |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 16 | 16 | 16 | 115 | 71.23 | 14.247 | direct |
| 16 | 16 | 32 | 163 | 100.52 | 20.103 | direct |
| 16 | 16 | 64 | 370 | 88.56 | 17.712 | software adapted via m=[1] n=[1] k=[2, 2] (2 commands) |
| 16 | 32 | 16 | 201 | 81.51 | 16.302 | direct |
| 16 | 32 | 32 | 370 | 88.56 | 17.712 | software adapted via m=[1] n=[1, 1] k=[2] (2 commands) |
| 16 | 32 | 64 | 784 | 83.59 | 16.718 | software adapted via m=[1] n=[1, 1] k=[2, 2] (4 commands) |
| 16 | 64 | 16 | 446 | 73.47 | 14.694 | software adapted via m=[1] n=[2, 2] k=[1] (2 commands) |
| 16 | 64 | 32 | 784 | 83.59 | 16.718 | software adapted via m=[1] n=[1, 1, 1, 1] k=[2] (4 commands) |
| 16 | 64 | 64 | 1612 | 81.31 | 16.262 | software adapted via m=[1] n=[1, 1, 1, 1] k=[2, 2] (8 commands) |
| 32 | 16 | 16 | 201 | 81.51 | 16.302 | direct |
| 32 | 16 | 32 | 370 | 88.56 | 17.712 | software adapted via m=[1, 1] n=[1] k=[2] (2 commands) |
| 32 | 16 | 64 | 784 | 83.59 | 16.718 | software adapted via m=[1, 1] n=[1] k=[2, 2] (4 commands) |
| 32 | 32 | 16 | 357 | 91.79 | 18.357 | direct |
| 32 | 32 | 32 | 758 | 86.46 | 17.292 | software adapted via m=[2] n=[2] k=[1, 1] (2 commands) |
| 32 | 32 | 64 | 1560 | 84.02 | 16.804 | software adapted via m=[2] n=[2] k=[1, 1, 1, 1] (4 commands) |
| 32 | 64 | 16 | 758 | 86.46 | 17.292 | software adapted via m=[2] n=[2, 2] k=[1] (2 commands) |
| 32 | 64 | 32 | 1560 | 84.02 | 16.804 | software adapted via m=[2] n=[2, 2] k=[1, 1] (4 commands) |
| 32 | 64 | 64 | 3164 | 82.85 | 16.570 | software adapted via m=[2] n=[2, 2] k=[1, 1, 1, 1] (8 commands) |
| 64 | 16 | 16 | 446 | 73.47 | 14.694 | software adapted via m=[2, 2] n=[1] k=[1] (2 commands) |
| 64 | 16 | 32 | 784 | 83.59 | 16.718 | software adapted via m=[1, 1, 1, 1] n=[1] k=[2] (4 commands) |
| 64 | 16 | 64 | 1612 | 81.31 | 16.262 | software adapted via m=[1, 1, 1, 1] n=[1] k=[2, 2] (8 commands) |
| 64 | 32 | 16 | 758 | 86.46 | 17.292 | software adapted via m=[2, 2] n=[2] k=[1] (2 commands) |
| 64 | 32 | 32 | 1560 | 84.02 | 16.804 | software adapted via m=[2, 2] n=[2] k=[1, 1] (4 commands) |
| 64 | 32 | 64 | 3164 | 82.85 | 16.570 | software adapted via m=[2, 2] n=[2] k=[1, 1, 1, 1] (8 commands) |
| 64 | 64 | 16 | 1560 | 84.02 | 16.804 | software adapted via m=[2, 2] n=[2, 2] k=[1] (4 commands) |
| 64 | 64 | 32 | 3164 | 82.85 | 16.570 | software adapted via m=[2, 2] n=[2, 2] k=[1, 1] (8 commands) |
| 64 | 64 | 64 | 6719 | 78.03 | 15.606 | software adapted via m=[2, 2] n=[2, 2] k=[1, 1, 1, 1] (16 commands) |

## Bottleneck Analysis

### 1. The dominant loss is per-command fixed overhead

The strongest pattern in the table is that throughput drops as software adaptation increases the number of commands:

- direct `1 cmd`: average `17.062 GOPS`
- `2 cmds`: average `16.800 GOPS`
- `4 cmds`: average `16.761 GOPS`
- `8 cmds`: average `16.447 GOPS`
- `16 cmds`: `15.606 GOPS`

This points to a fixed per-command tax that gets paid again every time software splits the target shape.

### 2. Best case happens when one command does enough work

The best result is:

- `16x16x32`: `20.103 GOPS`

This is better than `16x16x16` because the compute work doubles while the wrapper/control overhead is still paid only once.

### 3. Wrapper control staging is still the first-order bottleneck

From the existing wrapper perf note:

- full descriptor submission costs about `40 cycles` before the push
- wrapper adds only a small `+2/+4` cycle response overhead around PT
- export datapath after descriptor issue is close to native PT

So the main top-level loss is not arithmetic throughput inside PT; it is repeated AXI-Lite command staging and wrapper-visible command orchestration.

### 4. Software decomposition amplifies that overhead

For large combinations like `64x64x64`, software adapts to:

- `m=[2,2]`
- `n=[2,2]`
- `k=[1,1,1,1]`
- total `16` commands

That means the same control-path overhead is paid `16` times, which explains why:

- `64x64x64` drops to `15.606 GOPS`

even though the PT core itself is still executing valid work efficiently.

### 5. Export traffic is the second visible limiter as N grows

Cases with larger `N` increase output payload and export beats:

- `16x16x16`: `16` export beats
- `16x64x16`: `64` export beats
- `64x64x64`: `1024` export beats

This is not the primary limiter on small/medium shapes, but it becomes the next meaningful term after control overhead when command count is already high.

### 6. Practical ranking of bottlenecks

For the current `PT_DMA_TOP` software path, the likely bottleneck order is:

1. repeated AXI-Lite descriptor submission and command launch overhead
2. software decomposition increasing command count
3. export bandwidth / writeback beats on large-`N` or many-command cases
4. PT core compute/datapath itself

### 7. Immediate optimization direction

The highest-value next step on the software side is to reduce command count or command cost:

- prefer larger directly encodable sub-commands first
- reuse descriptor contents / `ctrl_id` when semantics allow
- avoid redundant AXI-Lite writes in wrapper mode

If you want better `64x64x64` numbers, reducing wrapper-side submission overhead will move the needle faster than trying to tune the PT datapath first.
