# PT_CE_V2 Warning Cleanup Iteration

- Timestamp: `2026-04-21 22:10:05 +0800`
- Branch: `codex-app`
- Commit baseline: `e6b626a`

## Scope

- Keep the `PT_CE_V2` macro-overlap performance gain
- reduce the additional SpyGlass warnings introduced by the drain-shadow implementation
- preserve numerical correctness

## Local Status

Files under active edit:

- `rtl/pt_ce_v2.v`

Local regression completed:

- `./scripts/synth_sanity.sh`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --target pt_dma_top --sim icarus --submission-mode compact --m 16 --k 64 --n 16`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`
  - `27/27 PASS`

So the warning-cleanup refactor did not break the current numerical behavior.

## SpyGlass

Remote rerun result:

- previous CE-overlap version:
  - `233 warnings`
- current cleanup version:
  - `178 warnings`

Delta:

- `-55 warnings`

This is a strong recovery and removes the bulk of the extra `PT_CE_V2` sequential multiple-assignment warnings introduced by the previous overlap patch.

## Performance

The local compact sweep still preserves the CE-overlap gains:

- `16x32x16`
  - `183 cycles`
- `32x16x16`
  - `183 cycles`
- `32x32x16`
  - `303 cycles`
- `64x64x64`
  - `5269 cycles`
  - `99.504 ops/cycle`
  - `19.901 GOPS @ 200MHz`

Wrapper-vs-native PT delta also remains improved:

- `16 cmd` wrapper tax is still about `22.312 cycles/cmd`

## Remote DC

- status:
  - `compile complete`
- log:
  - `synopsys/dc/logs/compile_20260421_221001.log`

Final QoR:

- setup:
  - `WNS = 0.00`
  - `TNS = 0.00`
- hold:
  - worst hold `-0.12ns`
  - hold TNS `-1122.22`
  - hold violating paths `24292`
- area:
  - `218091.404226`
- design rules:
  - `2` max-cap violations

Delta vs previous CE-overlap iteration:

- area:
  - old `218083.466224`
  - new `218091.404226`
  - delta `+7.938002`
  - essentially flat
- hold TNS magnitude:
  - old `1121.51`
  - new `1122.22`
  - delta `+0.71`
  - effectively flat

## Conclusion

This cleanup iteration is successful:

- local numerical regression still passes
- full `{1,2,4}^3` compact sweep still passes
- PT_DMA_TOP performance gains from the CE overlap patch are preserved
- SpyGlass warnings dropped from `233` to `178`
- remote DC QoR stayed essentially unchanged

That means the CE-overlap optimization is now in a much cleaner state for signoff and the next optimization target can move to:

- serialized `A/B` fill handling
