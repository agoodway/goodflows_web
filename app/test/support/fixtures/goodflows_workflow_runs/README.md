# goodflows workflow-run contract fixtures

Vendored, byte for byte, from the goodflows CLI repository:

- Source: `agoodway/goodflows`, `tests/fixtures/workflow-runs/`
- Commit: `4fa1da796a36135b9bcf219ba0db66c591884918` (the goodflows PR #20 merge)

| File | SHA-256 |
|---|---|
| `full.json` | `d16aba13f9d7881bd377df33fe72e75049fdf6a459c9499cf74a350ae41e880c` |
| `minimal.json` | `21d1f836e722bce28c959c1520745bc101c62ce2cb42d008faee20a9573b3eab` |
| `child.json` | `5d9e94e06d3a2c50193c7ef8b143ce618e411aad96a2ca9bf7020fed0a137b28` |
| `history-parent-default.json` | `885e038c0f9b987034b408e021199f81da87b707b7f19d97781cc9a1ff79b6dc` |
| `history-child-suite.json` | `72e944d953fea14064d52c743e85c247f1bbdcaacbf5a054def8053bab0020b1` |

goodflows validates these files against its client allowlist
(`src/reporting/run_contract.rs` at the same commit), and
`GoodFlowsWeb.Api.V1.WorkflowRunContractTest` uploads each one to this
server. `full.json` carries the whole upload envelope (`source.branch`,
`ci`, and `graph` with a workflow-call job). The two `history-*` files are
local history files without the envelope.

Tests read these copies and never fetch them. Do not edit or reformat them.
To change the contract, copy the files from a newer goodflows commit,
update the commit and digests above, and treat the change as a contract
change.
