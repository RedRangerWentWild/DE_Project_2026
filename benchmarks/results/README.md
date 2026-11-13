# Benchmark results

Every timing in [`docs/03_baseline_timings.md`](../../docs/03_baseline_timings.md) and [`docs/04_optimization_report.md`](../../docs/04_optimization_report.md) comes from a file in this folder. The plan files and `summary.csv` are written by [`run_benchmark.sh`](../run_benchmark.sh), the script given with the project.

| Folder | What ran | Database | Used in |
|--------|----------|----------|---------|
| `baseline/` | the 30 original queries, 3 runs each | Phase 3 state: constraints only, no tuning index | docs/03, and the "Before" column of docs/04 |
| `optimized/` | `sql/06_optimized_queries.sql`, 5 runs each | with `sql/05_indexes.sql` | the "After" column of docs/04 |
| `indexes_only/` | the 30 original queries again, 3 runs each | with `sql/05_indexes.sql` | docs/04 section 6: what the indexes did without the rewrites |
| `rejected/` | rewrites we tried and did not keep, each file with its query and 3 runs | with `sql/05_indexes.sql` | docs/04 section 9 |
| `write_overhead/` | each write query in one connection with `pgbench` (500 transactions, 100 for W04; the statements are in `scripts/`), W01 twice per new connection, and the refresh of the two summary tables | `practo_base` and `practo` | docs/04 section 7 |

Other files in `optimized/`:

| File | Content |
|------|---------|
| `result_check.txt` | The output of `../compare_results.sh practo_base practo`: the proof that the results are unchanged (docs/04 section 4) |
| `original_ties_repeat_runs.txt` | The original R21 and R10 run 10 times on the Phase 3 database: their tied rows already vary from run to run (section 4.3) |
| `index_sizes.txt` | The size of every index and summary table, against its table (section 8) |

`summary.csv` has one row per query:

| Column | Meaning |
|--------|---------|
| `query_id`, `type` | `R01` ... `W05`, and READ or WRITE |
| `avg_ms` | The mean of the runs' `Execution Time` lines: the figure in the reports |
| `median_ms`, `min_ms`, `max_ms` | The median, fastest and slowest of the same runs |
| `scan_nodes` | Every distinct scan in the plan of the last run, such as `Index Only Scan using ix_appt_slot_cover on appointments`; `(no scan)` when the plan has none |

Each plan file holds every run of one query, each headed `=== R19 run 1 ===`. Write queries ran inside `BEGIN ... ROLLBACK`, so the data never changed.
