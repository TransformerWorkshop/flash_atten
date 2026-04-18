# TSMC28 Logic Library Comparison

## Compared Families

- `tcbn28hpcplusbwp12t40p140_180a`
- `tcbn28hpcplusbwp40p140_180b`
- `tcbn28hpcplusbwp7t40p140_180b`

## Asset Completeness

### Functional Model Coverage (`vlg`)

- `12t40p140_180a`: `1186` modules
- `40p140_180b`: `1044` modules
- `7t40p140_180b`: `883` modules

### Backend Cell Coverage (`cdk`)

- `12t40p140_180a`: `1132` unique cell directories
- `40p140_180b`: `990` unique cell directories
- `7t40p140_180b`: `829` unique cell directories

### Common standard-cell evidence

All three functional-model sets include expected logic and sequential cells such as:

- `AN2D0`
- `INVD0`
- `BUFFD0`
- `ND2D0`
- `NR2D0`
- `OR2D0`
- `MUX2D0`
- `DFQD1`
- `DFCNQD1`

## Front-End Timing Library Usability

### NLDM status

Representative `tt/ff/ss` corners for `12t40p140_180a` and `40p140_180b` were checked and all remained reduced subsets:

- `12t` NLDM:
  - `tt`: `44` cells
  - `ff`: `44` cells
  - `ss`: `44` cells
- `40p` NLDM:
  - `tt`: `44` cells
  - `ff`: `44` cells
  - `ss`: `44` cells

These reduced libraries do not contain the full combinational/flip-flop set required for mapped DC synthesis.

### CCS status

- `7t40p140_180b`
  - `tt0p8v0p8v25c_ccs.db`: `44` cells only
  - `ffg0p99v0c_ccs.db`: `839` cells, full and DC-usable
- `7t40p140lvt_180b`
  - `ffg0p99v0c_ccs.db`: `839` cells, full and DC-usable
- `7t40p140hvt_180a`
  - `ffg0p99v0c_ccs.db`: `839` cells, full and DC-usable
- `12t40p140_180a`
  - `ffg0p99v0p99v0c_ccs.db`: `44` cells only
- `40p140_180b`
  - `ffg0p99v0p99v0c_ccs.db`: `44` cells only

## Practical Conclusion

### If the question is "which library package is more complete on disk?"

Ranking:

1. `12t40p140_180a`
2. `40p140_180b`
3. `7t40p140_180b`

### If the question is "which one is actually more usable for DC right now?"

Ranking:

1. `7t40p140_180b`
2. `7t40p140lvt_180b`
3. `7t40p140hvt_180a`
4. `12t40p140_180a`
5. `40p140_180b`

Reason:

- Only the `7t` family currently provides a complete, DC-usable `CCS ff` timing DB in the shared TSMC tree.
- `12t` and `40p` are richer as raw library assets, but their checked `NLDM/CCS` timing DBs remain reduced subsets and are not presently suitable as primary DC target libraries.

## Can 7t be used together with 7t HVT/LVT?

Yes, based on the currently checked `CCS ff` corner:

- base `7t`: full `CCS ff` DB
- `7t lvt`: full `CCS ff` DB
- `7t hvt`: full `CCS ff` DB

So a mixed-VT DC setup using `7t` + `7t lvt` + `7t hvt` is feasible in principle, provided:

- the same usable corner family is chosen across all three variants
- the three DBs are added together to `target_library/link_library`
- timing reports are interpreted on that specific corner basis

The current pure-TSMC working synthesis flow was validated using only the base `7t` `ffg0p99v0c_ccs.db` as target library.
