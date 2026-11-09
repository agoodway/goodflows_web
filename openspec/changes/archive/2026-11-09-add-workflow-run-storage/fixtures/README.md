# Run-history golden files

Source: goodflows PR #10 commit `88c5c33` (`openspec/changes/upload-run-history/fixtures/`). `goodflows 0.6.0` wrote them with `goodflows run --history` from that change's `fixtures/goodflows.toml`: workflow `default` has jobs `prepare` (`echo prepare`) and `call-suite` (`workflow = "suite"`), and workflow `suite` has job `work` (`echo work`).

Keep both files byte-identical. They are compact JSON with one trailing LF. Do not reformat them.

| File | sha256 |
|---|---|
| `parent-default.json` | `885e038c0f9b987034b408e021199f81da87b707b7f19d97781cc9a1ff79b6dc` |
| `child-suite.json` | `72e944d953fea14064d52c743e85c247f1bbdcaacbf5a054def8053bab0020b1` |

`parent-default.json` is the root run. Its `call-suite` result points at `child-suite.json` through `child_run_id`. The child points back with `parent_run_id` and `caller_job`. Neither file includes the upload-only keys `graph`, `ci`, or `source.branch`.
