# DC Compile Summary - TSMC 28nm 7T CCS FF

## Scope

- Project: `~/Desktop/flash_atten` on the Synopsys VM
- Design top: `PT_DMA_TOP`
- Library source: TSMC `7t40p140_180b`
- Active DC target library during successful mapped run:
  - `tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs.db`
- Constraint baseline:
  - `core_clk` created at `5.000 ns`
  - default input/output delays set to `0.500 ns`

## Key TSMC Findings

- The complete standard-cell set exists in TSMC `vlg/cdk` collateral:
  - `tcbn28hpcplusbwp7t40p140_110a_vlg.tar.gz`
  - `tcbn28hpcplusbwp7t40p140_110a_cdk.tar.gz`
- Those packages contain the expected full logic and sequential cells such as:
  - `AN2D0BWP7T40P140`
  - `INVD0BWP7T40P140`
  - `BUFFD0BWP7T40P140`
  - `ND2D0BWP7T40P140`
  - `NR2D0BWP7T40P140`
  - `OR2D0BWP7T40P140`
  - `MUX2D0BWP7T40P140`
  - `DFQD1BWP7T40P140`
  - `DFCNQD1BWP7T40P140`
- The frontend timing libraries are not uniformly complete across corners:
  - `tt0p8v0p8v25c_ccs.db` is a reduced subset with only `44` cells
  - `ffg0p99v0c_ccs.db` is a full library with `839` cells
- Because of that, the usable pure-TSMC DC flow currently targets the `ffg0p99v0c` CCS corner.

## Final Artifacts

- VM compile log:
  - `~/Desktop/flash_atten/logs/dc/compile_20260417_173028.log`
- VM reports:
  - `~/Desktop/flash_atten/reports/dc/PT_DMA_TOP/compile_qor.rpt`
  - `~/Desktop/flash_atten/reports/dc/PT_DMA_TOP/compile_area.rpt`
  - `~/Desktop/flash_atten/reports/dc/PT_DMA_TOP/compile_timing.rpt`
  - `~/Desktop/flash_atten/reports/dc/PT_DMA_TOP/compile_check_design.rpt`
- VM synthesis outputs:
  - `~/Desktop/flash_atten/results/dc/PT_DMA_TOP/PT_DMA_TOP_compile.ddc`
  - `~/Desktop/flash_atten/results/dc/PT_DMA_TOP/PT_DMA_TOP_compile.v`

## Report Highlights

- QoR:
  - Critical Path Length: `4.89 ns`
  - Critical Path Slack: `0.00 ns`
  - Total Negative Slack: `0.00`
  - Violating Paths: `0`
  - Cell Area: `112788.494103`
  - Design Area: `112788.494103`
- Area:
  - Number of ports: `27107`
  - Number of nets: `408552`
  - Number of cells: `235131`
  - Number of combinational cells: `141609`
  - Number of sequential cells: `93340`
  - Combinational area: `75400.024083`
  - Buf/Inv area: `3254.677920`
  - Noncombinational area: `37388.470020`
  - Total cell area: `112788.494103`
- Timing:
  - Report is constrained on `core_clk`
  - Paths are no longer reported as unconstrained
  - Representative reported slacks are `MET`

## Remaining Caveats

- `sram.v` is still a behavioral model, so SRAM arrays are synthesized into standard cells. The reported area is therefore not a final macro-based physical area.
- `compile_check_design.rpt` still reports many unconnected wrapper-side ports and hierarchical pin issues. These are mainly top-level sideband and modeling hygiene issues, not a sign that DC stayed in generic-only mode.
- `tt` CCS/NLDM timing collateral in the current shared TSMC tree is incomplete. If a true signoff-style multi-corner DC setup is needed, additional complete TSMC timing DB/LIB collateral is still required for `tt/ss`.
