# FA Extreme Precision Diagnostic

This report uses adversarial Q8.8 inputs to decompose precision loss into QK saturation/scale, row-state probability, PV quantization, and OACC quantization.

## Ranked Cases

| Rank | Case | Pass | Total mean | Total max | Worst stage max | Worst stage mean | QK sat | Prob L1 max |
|---:|---|---:|---:|---:|---|---|---:|---:|
| 1 | `random_amp32767_seed20260433_noncausal_q0` | no | 63.679005 | 133.984375 | `qk_saturation_scale` | `qk_saturation_scale` | 46.83% | 0.044081 |
| 2 | `random_amp32767_seed20260438_causal_q0` | no | 59.245407 | 129.722656 | `qk_saturation_scale` | `oacc_quantization` | 50.74% | 0.015625 |
| 3 | `qk_saturation_tie_flip` | no | 128.007812 | 128.007812 | `qk_saturation_scale` | `qk_saturation_scale` | 100.00% | 0.038844 |
| 4 | `oacc_uniform_vmax_noncausal` | no | 119.996094 | 119.996094 | `oacc_quantization` | `oacc_quantization` | 0.00% | 0.107684 |
| 5 | `oacc_uniform_vmin_noncausal` | no | 119.996094 | 119.996094 | `oacc_quantization` | `oacc_quantization` | 0.00% | 0.107684 |
| 6 | `causal_first_token_vmax` | no | 19.045037 | 119.996094 | `oacc_quantization` | `oacc_quantization` | 0.00% | 0.015625 |
| 7 | `random_amp16384_seed20260437_noncausal_q0` | no | 24.266129 | 56.210755 | `oacc_quantization` | `oacc_quantization` | 0.34% | 0.073636 |
| 8 | `random_amp16384_seed20260432_causal_q0` | no | 24.505024 | 55.710938 | `oacc_quantization` | `oacc_quantization` | 0.74% | 0.003906 |
| 9 | `p_lsb_many_tails_vmax` | no | 37.925062 | 37.925062 | `row_state_probability` | `row_state_probability` | 0.00% | 0.297042 |
| 10 | `random_amp4096_seed20260431_noncausal_q0` | no | 2.100041 | 8.578125 | `oacc_quantization` | `oacc_quantization` | 0.00% | 0.077920 |
| 11 | `random_amp4096_seed20260436_causal_q112` | no | 1.909692 | 8.218750 | `oacc_quantization` | `oacc_quantization` | 0.00% | 0.037402 |
| 12 | `random_amp1024_seed20260435_noncausal_q0` | no | 0.046313 | 0.269017 | `row_state_probability` | `row_state_probability` | 0.00% | 0.073201 |
| 13 | `p_lsb_single_tail_vmax` | no | 0.210999 | 0.210999 | `row_state_probability` | `row_state_probability` | 0.00% | 0.081508 |
| 14 | `random_amp1024_seed20260430_causal_q112` | yes | 0.016511 | 0.095898 | `row_state_probability` | `row_state_probability` | 0.00% | 0.035996 |
| 15 | `random_amp256_seed20260434_causal_q240` | yes | 0.021422 | 0.046801 | `pv_quantization` | `pv_quantization` | 0.00% | 0.130531 |
| 16 | `random_amp256_seed20260429_noncausal_q0` | yes | 0.020697 | 0.044424 | `pv_quantization` | `pv_quantization` | 0.00% | 0.137142 |

## Stage Detail

### random_amp32767_seed20260433_noncausal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=False, q_row_start=0
- QK saturation: 1918/4096 (46.83%), max_score_delta=18866.244209
- Probability: sum_avg=0.993411, sum_min=0.977411, sum_max=1.007256, l1_avg=0.032660, l1_max=0.044081, nonzero_avg=60.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | -93.097656 | -93.097656 |
| `qk_saturation_scale` | 63.263524 | 138.023438 | r12 c46 | 11.894531 | -126.128906 |
| `row_state_probability` | 0.317381 | 1.227888 | r15 c14 | -4.661946 | -3.434057 |
| `pv_quantization` | 0.016455 | 0.034142 | r8 c1 | -6.178100 | -6.143957 |
| `oacc_quantization` | 5.093397 | 29.055318 | r14 c37 | 6.136719 | 35.192037 |
| `total_vs_quantized_golden` | 63.679005 | 133.984375 | r12 c46 | 7.855469 | -126.128906 |
| `total_vs_float_golden` | 63.679005 | 133.984375 | r12 c46 | 7.855469 | -126.128906 |

### random_amp32767_seed20260438_causal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=True, q_row_start=0
- QK saturation: 69/136 (50.74%), max_score_delta=10947.519930
- Probability: sum_avg=0.997314, sum_min=0.984375, sum_max=1.000000, l1_avg=0.002686, l1_max=0.015625, nonzero_avg=2.38

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 66.402344 | 66.402344 |
| `qk_saturation_scale` | 24.672433 | 155.720703 | r13 c32 | -48.783203 | 106.937500 |
| `row_state_probability` | 0.112683 | 1.050734 | r15 c5 | 66.196228 | 67.246962 |
| `pv_quantization` | 0.002319 | 0.005829 | r11 c38 | -32.703125 | -32.697296 |
| `oacc_quantization` | 42.618622 | 118.914062 | r0 c61 | 8.000000 | 126.914062 |
| `total_vs_quantized_golden` | 59.245407 | 129.722656 | r13 c58 | -8.003906 | 121.718750 |
| `total_vs_float_golden` | 59.245407 | 129.722656 | r13 c58 | -8.003906 | 121.718750 |

### qk_saturation_tie_flip

- Description: Two very large QK scores both saturate to int32 max, erasing the exact ordering.
- Mode: causal=False, q_row_start=0
- QK saturation: 4096/4096 (100.00%), max_score_delta=126971.999985
- Probability: sum_avg=0.961156, sum_min=0.961156, sum_max=0.961156, l1_avg=0.038844, l1_max=0.038844, nonzero_avg=2.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 127.996094 | 127.996094 |
| `qk_saturation_scale` | 127.998047 | 127.998047 | r0 c0 | -0.001953 | 127.996094 |
| `row_state_probability` | 0.000076 | 0.000076 | r0 c0 | -0.001877 | -0.001953 |
| `pv_quantization` | 0.001877 | 0.001877 | r0 c0 | -0.003755 | -0.001877 |
| `oacc_quantization` | 0.007964 | 0.007964 | r0 c0 | -0.011719 | -0.003755 |
| `total_vs_quantized_golden` | 128.007812 | 128.007812 | r0 c0 | -0.011719 | 127.996094 |
| `total_vs_float_golden` | 128.007812 | 128.007812 | r0 c0 | -0.011719 | 127.996094 |

### oacc_uniform_vmax_noncausal

- Description: Uniform scores with full-range V, isolating the Q4.12 OACC range limit.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000000
- Probability: sum_avg=0.952418, sum_min=0.952418, sum_max=0.952418, l1_avg=0.107684, l1_max=0.107684, nonzero_avg=256.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 127.996094 | 127.996094 |
| `qk_saturation_scale` | 0.000000 | 0.000000 | r0 c0 | 127.996094 | 127.996094 |
| `row_state_probability` | 6.090325 | 6.090325 | r0 c0 | 121.905769 | 127.996094 |
| `pv_quantization` | 0.003478 | 0.003478 | r0 c0 | 121.909247 | 121.905769 |
| `oacc_quantization` | 113.909247 | 113.909247 | r0 c0 | 8.000000 | 121.909247 |
| `total_vs_quantized_golden` | 119.996094 | 119.996094 | r0 c0 | 8.000000 | 127.996094 |
| `total_vs_float_golden` | 119.996094 | 119.996094 | r0 c0 | 8.000000 | 127.996094 |

### oacc_uniform_vmin_noncausal

- Description: Uniform scores with full-range V, isolating the Q4.12 OACC range limit.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000000
- Probability: sum_avg=0.952418, sum_min=0.952418, sum_max=0.952418, l1_avg=0.107684, l1_max=0.107684, nonzero_avg=256.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | -128.000000 | -128.000000 |
| `qk_saturation_scale` | 0.000000 | 0.000000 | r0 c0 | -128.000000 | -128.000000 |
| `row_state_probability` | 6.090510 | 6.090510 | r0 c0 | -121.909490 | -128.000000 |
| `pv_quantization` | 0.032854 | 0.032854 | r0 c0 | -121.942344 | -121.909490 |
| `oacc_quantization` | 113.938437 | 113.938437 | r0 c0 | -8.003906 | -121.942344 |
| `total_vs_quantized_golden` | 119.996094 | 119.996094 | r0 c0 | -8.003906 | -128.000000 |
| `total_vs_float_golden` | 119.996094 | 119.996094 | r0 c0 | -8.003906 | -128.000000 |

### causal_first_token_vmax

- Description: Causal row 0 has a one-hot probability on a full-range V value, stressing final OACC range.
- Mode: causal=True, q_row_start=0
- QK saturation: 0/136 (0.00%), max_score_delta=0.000000
- Probability: sum_avg=0.998779, sum_min=0.984375, sum_max=1.015625, l1_avg=0.007568, l1_max=0.015625, nonzero_avg=8.50

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 127.996094 | 127.996094 |
| `qk_saturation_scale` | 0.000000 | 0.000000 | r0 c0 | 127.996094 | 127.996094 |
| `row_state_probability` | 0.106429 | 0.222215 | r8 c0 | 13.999573 | 14.221788 |
| `pv_quantization` | 0.000581 | 0.001953 | r1 c0 | 64.000000 | 63.998047 |
| `oacc_quantization` | 19.031006 | 119.996094 | r0 c0 | 8.000000 | 127.996094 |
| `total_vs_quantized_golden` | 19.045037 | 119.996094 | r0 c0 | 8.000000 | 127.996094 |
| `total_vs_float_golden` | 19.045037 | 119.996094 | r0 c0 | 8.000000 | 127.996094 |

### random_amp16384_seed20260437_noncausal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=False, q_row_start=0
- QK saturation: 14/4096 (0.34%), max_score_delta=530.808702
- Probability: sum_avg=0.959932, sum_min=0.926986, sum_max=0.996434, l1_avg=0.040672, l1_max=0.073636, nonzero_avg=3.69

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 27.964844 | 27.964844 |
| `qk_saturation_scale` | 1.081596 | 47.275391 | r4 c35 | 6.376953 | 53.652344 |
| `row_state_probability` | 1.265175 | 4.667274 | r9 c2 | -58.992700 | -63.659974 |
| `pv_quantization` | 0.002486 | 0.007796 | r4 c52 | -20.482066 | -20.474270 |
| `oacc_quantization` | 22.711658 | 54.729478 | r1 c50 | -7.878906 | -62.608384 |
| `total_vs_quantized_golden` | 24.266129 | 56.210755 | r9 c2 | -7.449219 | -63.659974 |
| `total_vs_float_golden` | 24.266129 | 56.210755 | r9 c2 | -7.449219 | -63.659974 |

### random_amp16384_seed20260432_causal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=True, q_row_start=0
- QK saturation: 1/136 (0.74%), max_score_delta=323.599344
- Probability: sum_avg=0.997559, sum_min=0.996094, sum_max=1.000000, l1_avg=0.002441, l1_max=0.003906, nonzero_avg=1.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 36.199219 | 36.199219 |
| `qk_saturation_scale` | 0.000000 | 0.000000 | r0 c0 | 36.199219 | 36.199219 |
| `row_state_probability` | 0.076110 | 0.248871 | r6 c15 | 63.462067 | 63.710938 |
| `pv_quantization` | 0.002235 | 0.005844 | r7 c12 | -9.464844 | -9.459000 |
| `oacc_quantization` | 24.431217 | 55.710938 | r5 c15 | 8.000000 | 63.710938 |
| `total_vs_quantized_golden` | 24.505024 | 55.710938 | r5 c15 | 8.000000 | 63.710938 |
| `total_vs_float_golden` | 24.505024 | 55.710938 | r5 c15 | 8.000000 | 63.710938 |

### p_lsb_many_tails_vmax

- Description: Many probabilities sit below one half of the Q8.8 P LSB and can disappear after P quantization.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000015
- Probability: sum_avg=0.704451, sum_min=0.704451, sum_max=0.704451, l1_avg=0.297042, l1_max=0.297042, nonzero_avg=1.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 37.925062 | 37.925062 |
| `qk_saturation_scale` | 0.000407 | 0.000407 | r0 c0 | 37.924654 | 37.925062 |
| `row_state_probability` | 37.924654 | 37.924654 | r0 c0 | 0.000000 | 37.924654 |
| `pv_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.000000 | 0.000000 |
| `oacc_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.000000 | 0.000000 |
| `total_vs_quantized_golden` | 37.925062 | 37.925062 | r0 c0 | 0.000000 | 37.925062 |
| `total_vs_float_golden` | 37.925062 | 37.925062 | r0 c0 | 0.000000 | 37.925062 |

### random_amp4096_seed20260431_noncausal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000021
- Probability: sum_avg=0.955695, sum_min=0.922080, sum_max=0.996912, l1_avg=0.044831, l1_max=0.077920, nonzero_avg=3.44

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 14.746094 | 14.746094 |
| `qk_saturation_scale` | 0.000003 | 0.000076 | r10 c22 | 7.009112 | 7.009035 |
| `row_state_probability` | 0.335371 | 1.246114 | r9 c34 | -14.746074 | -15.992187 |
| `pv_quantization` | 0.002720 | 0.011547 | r13 c33 | -2.151279 | -2.139732 |
| `oacc_quantization` | 1.770765 | 7.888233 | r7 c52 | -7.960938 | -15.849171 |
| `total_vs_quantized_golden` | 2.100041 | 8.578125 | r9 c34 | -7.414062 | -15.992187 |
| `total_vs_float_golden` | 2.100041 | 8.578125 | r9 c34 | -7.414062 | -15.992187 |

### random_amp4096_seed20260436_causal_q112

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=True, q_row_start=112
- QK saturation: 0/1928 (0.00%), max_score_delta=0.000021
- Probability: sum_avg=0.981885, sum_min=0.962598, sum_max=0.996436, l1_avg=0.018813, l1_max=0.037402, nonzero_avg=3.44

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 3.385127 | 3.385127 |
| `qk_saturation_scale` | 0.000001 | 0.000030 | r4 c46 | -11.756270 | -11.756240 |
| `row_state_probability` | 0.143893 | 0.596819 | r7 c0 | -15.360212 | -15.957031 |
| `pv_quantization` | 0.002292 | 0.006339 | r4 c37 | -8.545571 | -8.539232 |
| `oacc_quantization` | 1.771739 | 7.903483 | r11 c29 | -8.003906 | -15.907390 |
| `total_vs_quantized_golden` | 1.909692 | 8.218750 | r7 c0 | -7.738281 | -15.957031 |
| `total_vs_float_golden` | 1.909692 | 8.218750 | r7 c0 | -7.738281 | -15.957031 |

### random_amp1024_seed20260435_noncausal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000021
- Probability: sum_avg=0.963386, sum_min=0.931345, sum_max=0.985570, l1_avg=0.043619, l1_max=0.073201, nonzero_avg=23.50

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.690162 | 0.690162 |
| `qk_saturation_scale` | 0.000002 | 0.000014 | r7 c33 | 1.323131 | 1.323146 |
| `row_state_probability` | 0.048156 | 0.267887 | r8 c16 | -3.628764 | -3.896651 |
| `pv_quantization` | 0.009725 | 0.035134 | r5 c38 | -1.202063 | -1.166929 |
| `oacc_quantization` | 0.003491 | 0.009581 | r8 c21 | -0.175781 | -0.166200 |
| `total_vs_quantized_golden` | 0.046313 | 0.269017 | r8 c13 | 3.527344 | 3.796360 |
| `total_vs_float_golden` | 0.046313 | 0.269017 | r8 c13 | 3.527344 | 3.796360 |

### p_lsb_single_tail_vmax

- Description: A single high-value V tail sits near the Q8.8 P rounding boundary.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000015
- Probability: sum_avg=0.918492, sum_min=0.918492, sum_max=0.918492, l1_avg=0.081508, l1_max=0.081508, nonzero_avg=1.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.210999 | 0.210999 |
| `qk_saturation_scale` | 0.000003 | 0.000003 | r0 c0 | 0.210996 | 0.210999 |
| `row_state_probability` | 0.210996 | 0.210996 | r0 c0 | 0.000000 | 0.210996 |
| `pv_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.000000 | 0.000000 |
| `oacc_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.000000 | 0.000000 |
| `total_vs_quantized_golden` | 0.210999 | 0.210999 | r0 c0 | 0.000000 | 0.210999 |
| `total_vs_float_golden` | 0.210999 | 0.210999 | r0 c0 | 0.000000 | 0.210999 |

### random_amp1024_seed20260430_causal_q112

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=True, q_row_start=112
- QK saturation: 0/1928 (0.00%), max_score_delta=0.000021
- Probability: sum_avg=0.987266, sum_min=0.968663, sum_max=0.998126, l1_avg=0.017706, l1_max=0.035996, nonzero_avg=20.50

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | 0.638572 | 0.638572 |
| `qk_saturation_scale` | 0.000002 | 0.000014 | r12 c55 | -0.082922 | -0.082908 |
| `row_state_probability` | 0.016386 | 0.090095 | r13 c14 | 3.122989 | 3.213084 |
| `pv_quantization` | 0.005970 | 0.026965 | r13 c61 | -2.779064 | -2.752098 |
| `oacc_quantization` | 0.003833 | 0.009314 | r13 c60 | -1.250000 | -1.240686 |
| `total_vs_quantized_golden` | 0.016511 | 0.095898 | r13 c14 | 3.117188 | 3.213085 |
| `total_vs_float_golden` | 0.016511 | 0.095898 | r13 c14 | 3.117188 | 3.213085 |

### random_amp256_seed20260434_causal_q240

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=True, q_row_start=240
- QK saturation: 0/3976 (0.00%), max_score_delta=0.000021
- Probability: sum_avg=0.995086, sum_min=0.976844, sum_max=1.013509, l1_avg=0.123385, l1_max=0.130531, nonzero_avg=248.00

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | -0.058112 | -0.058112 |
| `qk_saturation_scale` | 0.000000 | 0.000001 | r11 c13 | 0.026788 | 0.026787 |
| `row_state_probability` | 0.004720 | 0.024441 | r0 c63 | 0.009315 | 0.033757 |
| `pv_quantization` | 0.017048 | 0.034555 | r1 c8 | -0.093852 | -0.059298 |
| `oacc_quantization` | 0.003973 | 0.008064 | r8 c50 | -0.097656 | -0.089592 |
| `total_vs_quantized_golden` | 0.021422 | 0.046801 | r1 c8 | -0.101562 | -0.054762 |
| `total_vs_float_golden` | 0.021422 | 0.046801 | r1 c8 | -0.101562 | -0.054762 |

### random_amp256_seed20260429_noncausal_q0

- Description: Random Q/K/V sweep at a selected raw Q8.8 amplitude.
- Mode: causal=False, q_row_start=0
- QK saturation: 0/4096 (0.00%), max_score_delta=0.000021
- Probability: sum_avg=1.002469, sum_min=0.978885, sum_max=1.017167, l1_avg=0.126435, l1_max=0.137142, nonzero_avg=255.25

| Stage | Mean abs | Max abs | Worst element | Actual | Expected |
|---|---:|---:|---|---:|---:|
| `input_quantization` | 0.000000 | 0.000000 | r0 c0 | -0.000263 | -0.000263 |
| `qk_saturation_scale` | 0.000000 | 0.000001 | r6 c25 | 0.033644 | 0.033643 |
| `row_state_probability` | 0.004576 | 0.018017 | r5 c21 | -0.052605 | -0.034588 |
| `pv_quantization` | 0.016626 | 0.029419 | r14 c22 | -0.111743 | -0.082324 |
| `oacc_quantization` | 0.004091 | 0.008070 | r14 c21 | -0.089844 | -0.081774 |
| `total_vs_quantized_golden` | 0.020697 | 0.044424 | r2 c54 | -0.078125 | -0.033701 |
| `total_vs_float_golden` | 0.020697 | 0.044424 | r2 c54 | -0.078125 | -0.033701 |

