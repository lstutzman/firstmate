# fm-supervision-host flake fix: base vs fix matrix (Linux, deepthought)
| Case | base 9a963566 | fix 251cd171 |
|---|---|---|
| Full tests/fm-supervision-host.test.sh | (per intent: fails on main) | pass 3/3 (head-run-{1,2,3}.log) |
| drain cannot print (old fixture `>&-`) | FAIL: missing '[seq 1] demo: merged the docs fix' (base-drain-case.log) | n/a |
| drain cannot print (new fixture `1</dev/null`) against base bin | pass (basebin-newtest-drain-case.log) -> fixture-only defect | pass |
| hook write failure: Stop hook finishes and notifies (rc 2) | FAIL 3/3 'the Stop hook did not finish' after ~27s (base-hook-write-failure-*.log) | pass 3/3 in ~3s (head-hook-write-failure-*.log) |
