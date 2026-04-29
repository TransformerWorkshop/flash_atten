# FA_RUN_CTRL

RTL: [`rtl/fa_run_ctrl.v`](../../../rtl/fa_run_ctrl.v)

`FA_RUN_CTRL` 管理一次 accelerator run 的生命周期，并生成软件可见的 busy/done/error/cycles。

```text
+--------------------------------------------------------------+
| FA_RUN_CTRL                                                  |
|                                                              |
| start_pulse                                                  |
| soft_reset_pulse                                             |
| clear                                                        |
| run_complete_pulse                                           |
| run_error_pulse                                              |
|        |                                                     |
|        v                                                     |
| +--------------------+                                       |
| | lifecycle registers |                                      |
| | run_active_r        |-----> run_active / busy              |
| | done_sticky_r       |-----> done_sticky                    |
| | error_sticky_r      |-----> error_sticky                   |
| | cycles_r            |-----> cycles                         |
| +--------------------+                                       |
|                                                              |
| State behavior:                                              |
| IDLE --start_pulse--> RUN                                    |
| RUN  --run_complete_pulse--> DONE_STICKY                     |
| RUN  --run_error_pulse-----> ERROR_STICKY                    |
| any  --clear/soft_reset----> IDLE                            |
| RUN increments cycles once per clock.                        |
+--------------------------------------------------------------+
```

该模块不直接理解 tile 或 DMA，只消费 scheduler/error 返回的完成信号，因此是 core 控制面的最小状态源。
