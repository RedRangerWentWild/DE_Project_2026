# Phase 4 - Optimization report

**Team T0015 (Bluetrace), Section E**

| | Before (Phase 3) | After (Phase 4) |
|---|---:|---:|
| Total of the 30 average times | **6,747.052 ms** | **290.812 ms** (95.7% less, 23x faster) |
| Total without R19 (the one pathological query) | 806.990 ms | 276.880 ms (65.7% less) |
| Slowest query | R19, 5,940.062 ms | R24, 62.321 ms |
| Queries that return a wrong answer | 1 (R13 returns 0 rows) | 0 (R13 returns the 292 clinics) |

What we changed: **7 indexes and 2 summary tables** ([`sql/05_indexes.sql`](../sql/05_indexes.sql)) and **12 rewritten queries** ([`sql/06_optimized_queries.sql`](../sql/06_optimized_queries.sql)). The other 18 queries are byte-for-byte the originals; they are faster because of the indexes alone. Every timing below comes from the raw plans in [`benchmarks/results/`](../benchmarks/results/).

## 1. How we measured

- **Same machine, same server settings as Phase 3** (Intel Xeon 2.10 GHz, 4 vCPU, 16 GB, PostgreSQL 16.15, default configuration, `timezone = Asia/Kolkata`; see `docs/03_baseline_timings.md`). We changed no server setting: no `work_mem`, no `enable_*`, no `random_page_cost`, JIT left on.
- **Same database.** `sql/05_indexes.sql` was run on the database used for Phase 3; nothing else changed. Before that, a copy was kept (`createdb -T practo practo_base`) so that before and after can be compared side by side.
- **Optimized run** ([`benchmarks/results/optimized/`](../benchmarks/results/optimized/)): `./benchmarks/run_benchmark.sh practo optimized 5 sql/06_optimized_queries.sql`, i.e. 5 runs per query as given in the brief. As in Phase 3, one warm-up pass was run first and discarded; then `VACUUM (ANALYZE)` (the warm-up's rolled-back writes leave dead row versions behind, which autovacuum would remove on a live server).
- **Indexes-only run** ([`benchmarks/results/indexes_only/`](../benchmarks/results/indexes_only/)): the *original* `queries/workload_30.sql` on the indexed database (3 runs). It separates what the indexes did from what the rewrites did (section 6).
- **Proof that results are unchanged**: [`benchmarks/compare_results.sh`](../benchmarks/compare_results.sh), output in [`optimized/result_check.txt`](../benchmarks/results/optimized/result_check.txt) (section 4).
- **Write overhead and storage**: [`benchmarks/results/write_overhead/`](../benchmarks/results/write_overhead/) and [`optimized/index_sizes.txt`](../benchmarks/results/optimized/index_sizes.txt) (sections 7 and 8).
- **Rewrites we tried and rejected**: [`benchmarks/results/rejected/`](../benchmarks/results/rejected/) (section 9).

## 2. The optimization table

"Before" is the Phase 3 average (3 runs); "After" is the Phase 4 average (5 runs). Improvement % = (before - after) / before x 100.

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|-------|------------:|---------------------------|----------------------|-----------:|------------:|:------------:|
| R01 | 4.079 | Small tables, already uses `doctors_pkey` and `pk_doctor_schedules`; the join yields 366 rows that `DISTINCT` collapses | None kept. An `EXISTS` rewrite was slower (section 9) | 4.000 | 1.9% (noise) | ✅ identical |
| R02 | 0.727 | Hash table of all 1,500 clinics built to look up 9; extra sort | Scalar subquery on `clinics_pkey` (9 lookups); rows already in PK order, so no sort | 0.100 | 86.2% (7.3x) | ✅ identical |
| R03 | 18.217 | Seq Scan of 150,000 appointments to find doctor 217's 72 active ones | `ix_appt_doctor_slot (doctor_id, slot_start) INCLUDE (status, ...)` → Index Only Scan | 0.173 | 99.1% (105x) | ✅ identical |
| R04 | 14.973 | Seq Scan of 150,000 rows to return 2 (no index on `patient_id`) | `ix_appt_patient (patient_id, doctor_id, slot_start)` | 0.226 | 98.5% (66x) | ✅ identical |
| R05 | 11.672 | `DATE(slot_start)` not sargable; parallel Seq Scan for 3 rows | Rewrite to a half-open range on `slot_start` + `ix_appt_doctor_slot` | 0.130 | 98.9% (90x) | ✅ identical |
| R06 | 0.049 | None: `uq_patients_phone` lookup | None | 0.061 | -24.5% (noise, 12 µs; plan unchanged) | ✅ identical |
| R07 | 0.141 | None: two constraint-index lookups | None | 0.124 | 12.1% (noise; plan unchanged) | ✅ identical |
| R08 | 46.566 | `EXTRACT(YEAR ...)` not sargable, estimate 57x too low; 44,666 rows hashed against specializations and sorted | Range on `slot_start` → Index Only Scan on `ix_appt_slot_cover`; count per doctor first, join 3,000 rows instead of 44,666 | 17.038 | 63.4% (2.7x) | ✅ identical |
| R09 | 16.307 | Seq Scan of 150,000 rows for 5,622 June visits | `ix_appt_slot_cover` range: reads only June's pages (Bitmap Heap Scan) | 5.270 | 67.7% (3.1x) | ✅ same rows ¹ |
| R10 | 45.581 | Seq Scan of 40,000 patients for 1,737; hash join with all 150,000 appointments | GIN `ix_patients_allergies`; the planner still prefers one pass over appointments to 1,737 random probes (section 9) | 41.925 | 8.0% (1.1x) | ✅ same rows ¹ |
| R11 | 35.286 | Seq Scan of 97,234 prescriptions for 430; Hash Anti Join over 135,100 appointments | Partial `ix_presc_followup` + `ix_appt_patient`: Nested Loop Anti Join with 430 Index Only probes | 2.553 | 92.8% (14x) | ✅ same rows ¹ |
| R12 | 57.608 | `EXTRACT(YEAR ...)` not sargable, estimate 69x too low → sorts 51,501 rows | Range on `slot_start` → Index Only Scan + HashAggregate instead of sorting 51,501 rows | 20.421 | 64.6% (2.8x) | ✅ identical |
| R13 | 8.575 | **Wrong answer**: `NOT IN` over a subquery with NULLs returns 0 rows | `NOT EXISTS` (correct: 292 clinics) + `ix_sched_clinic` for the anti-join | 1.269 | 85.2% (6.8x) and **now correct** | ❌ → ✅ fixed (0 → 292 rows), section 3 |
| R14 | 53.155 | All 30,339 reviews joined to all 150,000 appointments on every call | Summary table `doctor_rating_summary` (refreshed nightly) | 1.252 | 97.6% (42x) | ✅ identical |
| R15 | 59.510 | No index on `issued_at`; hash joins over the full items (243k) and appointments tables | Summary table `monthly_medicine_by_specialization` (refreshed nightly) | 0.438 | 99.3% (136x) | ✅ same rows ¹ |
| R16 | 19.621 | Seq Scan of 150,000 rows for 6,362 June PAID rows | `ix_appt_slot_cover` range (Bitmap Heap Scan of June) | 5.586 | 71.5% (3.5x) | ✅ identical |
| R17 | 102.859 | `age()` evaluated up to 3x per row; 41,907 groups expected (36 real) → sort of 40,670 rows | Index Only Scan on `ix_appt_slot_cover`; `age()` computed once in a `MATERIALIZED` CTE; HashAggregate | 55.094 | 46.4% (1.9x) | ✅ identical |
| R18 | 8.906 | `JOIN` + `DISTINCT` sorts 2,880 rows to return 360 doctors | `EXISTS` semi-join, no `DISTINCT` | 5.877 | 34.0% (1.5x) | ✅ identical |
| R19 | **5,940.062** | Two correlated subqueries x 480 doctors, each a Seq Scan: 144 M rows, 2.6 M buffers per run; cost 30.9 M triggers 221-244 ms of JIT | `ix_appt_doctor_slot` with `INCLUDE (status, consult_ended_at)`: 960 Index Only lookups; cost falls to 54.8 k, below `jit_above_cost`, so no JIT. **Query text unchanged** | 13.932 | **99.8% (426x)** | ✅ identical |
| R20 | 15.714 | `slot_start::date` not sargable | Range on `slot_start` → Index Only Scan of June | 3.733 | 76.2% (4.2x) | ✅ identical |
| R21 | 18.771 | Seq Scan + top-N sort of 24,683 rows to return 100 | `ix_appt_slot_cover` read backwards; stops after the 100th match | 0.803 | 95.7% (23x) | ✅ ² (tie at row 100) |
| R22 | 86.719 | `OFFSET 100000`: sorts all 150,000 rows (spills 6 MB to disk), discards 100,000 | Keyset pagination on `(slot_start, appointment_id)` with `ix_appt_slot_cover`: 25 index entries | 0.065 | **99.9% (1,334x)** | ✅ ² (tie at row 100,000) |
| R23 | 0.067 | None: `uq_doctors_registration_no` lookup | None | 0.050 | 25.4% (noise; plan unchanged) | ✅ identical |
| R24 | 67.173 | Self-join of all 135,100 active appointments | None kept: must compare every active appointment; two rewrites were slower (section 9) | 62.321 | 7.2% (noise) | ✅ same rows ¹ |
| R25 | 50.801 | Reads a third of the table; `count(DISTINCT)` needs a sort of 40,670 rows | Index Only Scan on `ix_appt_slot_cover` (no heap reads) | 38.699 | 23.8% (1.3x) | ✅ identical |
| W01 | 0.931 | None: indexed lookups + 3 FK checks | None. Slower because the row now goes into 5 indexes, and each new connection opens them (section 7) | 1.863 | -100.1% (see section 7) | ✅ identical |
| W02 | 17.019 | Seq Scan of 150,000 rows for the earliest July 1 booking; 11 rows tie for "earliest" | `ix_appt_slot_cover` in `(slot_start, appointment_id)` order, Index Only, `LIMIT 1`; tiebreaker makes the choice deterministic | 0.396 | 97.7% (43x) | ✅ identical (appointment 147590 in both) |
| W03 | 0.332 | None: `uq_prescriptions_appointment` lookup | None (now also maintains `ix_presc_followup`) | 0.345 | -3.9% (noise) | ✅ identical |
| W04 | 26.508 | Seq Scan of 150,000 rows to change 329 | Partial index `ix_appt_open_slot_end (slot_end) WHERE status IN ('BOOKED','CHECKED_IN')` (1,823 rows) | 6.592 | 75.1% (4.0x) | ✅ identical |
| W05 | 19.123 | Seq Scan of 150,000 rows to cancel 3 | `ix_appt_doctor_slot` (doctor 504, one day) | 0.476 | 97.5% (40x) | ✅ identical |
| **Total** | **6,747.052** | | | **290.812** | **95.7% (23.2x)** | |

¹ Same rows; rows whose `ORDER BY` keys are equal may come out in a different order, which the `ORDER BY` allows.
² Same number of rows and the same sort-key sequence; one tied row at the `LIMIT`/`OFFSET` edge differs, and the original query itself does not define which tied row belongs there (section 4.3).

## 3. The wrong-result query: R13 and the NULL rule

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE c.clinic_id NOT IN (SELECT sc.clinic_id FROM doctor_schedules sc);   -- returns 0 rows
```

**What happens.** `doctor_schedules.clinic_id` is NULL for the 5,899 video blocks. SQL uses three-valued logic: `x NOT IN (a, b, NULL)` means `x <> a AND x <> b AND x <> NULL`, and `x <> NULL` is neither TRUE nor FALSE but UNKNOWN. So for a clinic that appears nowhere in the list, the whole condition is `TRUE AND TRUE AND ... AND UNKNOWN` = UNKNOWN, and `WHERE` keeps only TRUE rows. For a clinic that does appear, it is FALSE. No clinic can ever pass, whatever the data. That is exactly the complaint in P5: "the list is always empty".

Checked on the database:

```
SELECT 5 NOT IN (1, 2, NULL)  -> NULL (unknown)
SELECT 5 NOT IN (1, 2)        -> true
SELECT 5 <> NULL              -> NULL (unknown)
```

**The fix.** `NOT EXISTS (SELECT 1 FROM doctor_schedules sc WHERE sc.clinic_id = c.clinic_id)` asks "is there a row?", which is always TRUE or FALSE. A NULL `clinic_id` simply never equals anything, so video blocks are ignored. (Filtering the NULLs out of the subquery, `NOT IN (SELECT clinic_id ... WHERE clinic_id IS NOT NULL)`, also gives 292 rows, but `NOT EXISTS` is the habit that cannot break the next time someone adds a nullable column.) With `ix_sched_clinic` the plan is an anti-join that probes the index once per clinic: 1.269 ms.

**Proof that 292 is right**, three independent ways (run on the database):

| Check | Result |
|-------|-------:|
| clinics in total | 1,500 |
| distinct non-NULL `clinic_id` values in `doctor_schedules` | 1,208 → 1,500 - 1,208 = **292** |
| `NOT EXISTS` result vs `LEFT JOIN doctor_schedules ... WHERE sc.clinic_id IS NULL` (EXCEPT both ways) | 0 differing rows |
| appointments at the 292 clinics (there must be none, since every in-clinic appointment is at a clinic where the doctor has a schedule, check IC2 in Phase 2) | 0 |

The 292 clinics by city: Bengaluru 71, Mumbai 72, Delhi 71, Hyderabad 18, Chennai 18, Pune 12, Kolkata 12, Ahmedabad 6, Jaipur 6, Lucknow 6. This is the list Clinic partnerships was missing.

## 4. Proof that the results are unchanged

### 4.1 Method

[`benchmarks/compare_results.sh`](../benchmarks/compare_results.sh) runs the **original** queries on the Phase 3 database (`practo_base`) and the **optimized** queries on the indexed database (`practo`), so it compares exactly what a user saw before and after. For each read query it records:

- **rows**: row count of each result;
- **set**: md5 of the rows sorted as text, i.e. the same rows regardless of order (a checksum version of `EXCEPT` in both directions);
- **keys**: md5 of only the `ORDER BY` columns, in the order the query returned them, i.e. the same order up to ties.

For each write query (inside `BEGIN ... ROLLBACK`) it records how many rows changed and an md5 of **every changed row after the change**, found by `xmin` = the current transaction. That proves the same rows were changed in the same way, not just the same number of rows.

### 4.2 Result ([`result_check.txt`](../benchmarks/results/optimized/result_check.txt))

| Verdict | Meaning | Queries |
|---------|---------|---------|
| IDENTICAL | same rows in the same order (for writes: the same rows changed to the same values) | R01-R08, R12, R14, R16-R20, R23, R25 and W01-W05 (22: 17 reads, 5 writes) |
| SAME | same set of rows and same sort-key sequence; only rows with equal sort keys are in a different order | R09, R10, R11, R15, R24 |
| TIES | same row count and same sort-key sequence; one row differs, inside a tie at the `LIMIT`/`OFFSET` edge | R21, R22 |
| DIFFERENT | | R13 only (0 → 292 rows, the intended fix) |

This includes the two summary-table queries (R14, R15): fresh summary tables give exactly the live answer. For the 18 queries whose text did not change, it also shows the indexes did not change their answers.

### 4.3 The tie cases, explained

Several of the original queries are **not deterministic**: their `ORDER BY` does not decide between some rows, so which of those rows end up inside a `LIMIT` depends on the plan. Any plan change, even a new index with the query untouched, can change the answer. We checked each case:

| Query | Tie | What differs | Why both answers are correct |
|-------|-----|--------------|------------------------------|
| R21 | 6 appointments at 29 June 10:30 share positions 99-104; only 2 fit in the top 100 | original returns 147691, optimized returns 149073 (both 29 June 10:30) | `ORDER BY slot_start DESC` gives all six the same rank |
| R22 | 8 appointments at 8 July 2025 12:15 occupy positions 99,997-100,004; 4 of them fall on page 4,001 | original includes 50125 and 50484, optimized 48675 and 49363 (all at 12:15) | `OFFSET 100000` cuts through the tie group |
| R14, R16 | positions 19-21 tie (R14: 4.42 avg with 12 reviews; R16: 10,600.00 collected) | nothing this time: both plans happened to pick the same rows | they *could* differ under another plan |
| W02 | 11 BOOKED in-clinic appointments share the earliest slot, 1 July 10:00 | nothing: both check in appointment 147590 (patient 19795) | the original picks whichever row its plan meets first; the rewrite (`ORDER BY slot_start, appointment_id`) always picks the earliest booking, which is the row the original happened to pick |

For R22 and W02 we went further than "same result" and made them deterministic with a tiebreaker (`appointment_id`), because a support console that can skip or repeat a row between pages, and a check-in that picks a random patient, are bugs. Every result of the rewritten queries is still one of the answers the original could have returned.

## 5. Before/after plans: the five biggest improvements

By Improvement %: R22 (99.9%), R19 (99.8%), R15 (99.3%), R03 (99.1%), R05 (98.9%). Excerpts from the raw files (run 3 of each; costs and some detail lines shortened).

### R22 - keyset pagination (86.719 → 0.065 ms)

Before ([`baseline/R22.txt`](../benchmarks/results/baseline/R22.txt)): every row is sorted, and the sort does not fit in memory.
```
Limit  (actual time=76.070..76.075 rows=25)
  ->  Sort  (actual time=63.862..72.250 rows=100025)
        Sort Key: slot_start DESC
        Sort Method: external merge  Disk: 6176kB
        ->  Seq Scan on appointments  (actual time=0.010..19.419 rows=150000)
Execution Time: 76.830 ms
```
After ([`optimized/R22.txt`](../benchmarks/results/optimized/R22.txt)): start right after the bookmark and read 25 index entries.
```
Limit  (actual time=0.023..0.034 rows=25)
  ->  Index Only Scan Backward using ix_appt_slot_cover on appointments  (actual time=0.022..0.031 rows=25)
        Index Cond: (ROW(slot_start, appointment_id) < ROW('2025-07-08 12:15:00+05:30', 50125))
        Heap Fetches: 0
Execution Time: 0.063 ms
```
OFFSET costs grow with the page number (page 4,001 reads 100,025 rows; on the 20x data it would read 2 million); keyset costs the same on every page. Even with the index, the original OFFSET query still took 15.999 ms (indexes-only run), because it must walk 100,025 index entries; the rewrite is what removes that.

### R19 - correlated subqueries backed by an index (5,940.062 → 13.932 ms)

Before ([`baseline/R19.txt`](../benchmarks/results/baseline/R19.txt)):
```
Sort  (cost=30946462.24..30946469.74 rows=3000) (actual time=5551.392..5551.442 rows=480)
  ->  Hash Semi Join  (actual time=262.727..5550.685 rows=480)
        ...
        SubPlan 1
          ->  Aggregate  (actual time=6.192..6.192 rows=1 loops=480)
                ->  Seq Scan on appointments a  (actual time=5.865..6.188 rows=2 loops=480)
                      Rows Removed by Filter: 149998
        SubPlan 2
          ->  Aggregate  (actual time=4.845..4.845 rows=1 loops=480)
                ->  Seq Scan on appointments a_1  (actual time=0.097..4.833 rows=50 loops=480)
                      Rows Removed by Filter: 149950
JIT:
  Timing: Generation 1.055 ms, Inlining 60.605 ms, Optimization 112.305 ms, Emission 70.178 ms, Total 244.143 ms
Execution Time: 5565.739 ms
```
After ([`optimized/R19.txt`](../benchmarks/results/optimized/R19.txt)), same SQL text:
```
Sort  (cost=54832.24..54839.74 rows=3000) (actual time=18.252..18.296 rows=480)
  ->  Hash Semi Join  (actual time=7.785..18.033 rows=480)
        ...
        SubPlan 1
          ->  Aggregate  (actual time=0.005..0.005 rows=1 loops=480)
                ->  Index Only Scan using ix_appt_doctor_slot on appointments a  (actual time=0.004..0.004 rows=2 loops=480)
                      Index Cond: ((doctor_id = d.doctor_id) AND (slot_start >= '2026-06-01 ...') AND (slot_start < '2026-07-01 ...'))
                      Filter: ((status)::text = 'COMPLETED'::text)
                      Heap Fetches: 50
        SubPlan 2
          ->  Aggregate  (actual time=0.013..0.013 rows=1 loops=480)
                ->  Index Only Scan using ix_appt_doctor_slot on appointments a_1  (actual time=0.004..0.009 rows=50 loops=480)
                      Index Cond: (doctor_id = d.doctor_id)
                      Heap Fetches: 123
Execution Time: 18.456 ms
```
The lesson: a correlated subquery is a nested loop written differently. It was slow because its inner side was a full table scan, not because it is a subquery. With `(doctor_id, slot_start)` as the key and `status, consult_ended_at` in `INCLUDE`, each of the 960 executions reads only that doctor's index entries and never the table. The estimated cost fell from 30.9 million to 54.8 thousand, below `jit_above_cost` (100,000), so PostgreSQL also stopped spending ~230 ms compiling the plan.

### R15 - summary table (59.510 → 0.438 ms)

Before ([`baseline/R15.txt`](../benchmarks/results/baseline/R15.txt)): five-table join, full scans of items and appointments.
```
Incremental Sort  (actual time=56.622..59.136 rows=225)
  ->  Finalize GroupAggregate ...
        ->  Parallel Hash Join  (actual time=49.295..51.820 rows=6874 loops=2)
              ->  Parallel Seq Scan on prescription_items i  (rows=121542 loops=2)
              ->  Parallel Hash
                    ->  Hash Join ... ->  Parallel Seq Scan on appointments a  (rows=75000 loops=2)
                                      ->  Seq Scan on prescriptions p  (rows=5503 loops=2)
                                            Rows Removed by Filter: 91731
Execution Time: 59.354 ms
```
After ([`optimized/R15.txt`](../benchmarks/results/optimized/R15.txt)):
```
Sort  (actual time=0.359..0.370 rows=225)
  ->  Bitmap Heap Scan on monthly_medicine_by_specialization  (actual time=0.045..0.161 rows=225)
        ->  Bitmap Index Scan on ux_monthly_medicine
              Index Cond: (month = '2026-06-01'::date)
Execution Time: 0.425 ms
```
The join work moved to the nightly refresh (281 ms on average, section 7). June 2026 is a closed month, so its 225 rows never change again.

### R03 - index-only anti-join (18.217 → 0.173 ms)

Before: `Merge Anti Join` whose inner side is `Seq Scan on appointments ... Filter: ((status)::text <> 'CANCELLED') AND (doctor_id = 217); Rows Removed by Filter: 149928` (15.305 ms).
After:
```
Merge Anti Join  (actual time=0.089..0.091 rows=12)
  ->  Sort (12 generated slots)
  ->  Index Only Scan using ix_appt_doctor_slot on appointments a  (actual time=0.030..0.037 rows=72)
        Index Cond: (doctor_id = 217)
        Filter: ((status)::text <> 'CANCELLED'::text)
        Heap Fetches: 0
Execution Time: 0.145 ms
```

### R05 - sargable rewrite (11.672 → 0.130 ms)

Before: `Parallel Seq Scan on appointments a ... Filter: ((doctor_id = 16) AND (date(slot_start) = '2026-06-30'::date)); Rows Removed by Filter: 74998` per worker (9.893 ms).
After:
```
Nested Loop  (actual time=0.044..0.072 rows=3)
  ->  Index Scan using ix_appt_doctor_slot on appointments a  (actual time=0.028..0.037 rows=3)
        Index Cond: ((doctor_id = 16) AND (slot_start >= '2026-06-30 00:00:00+05:30') AND (slot_start < '2026-07-01 00:00:00+05:30'))
  ->  Index Scan using patients_pkey on patients p  (rows=1 loops=3)
Execution Time: 0.134 ms
```
The index alone was not enough: with `DATE(slot_start)` still in the query, the indexes-only run used `doctor_id` only, read all 151 of doctor 16's appointments and threw away 148 (0.515 ms). Only the range form lets the index jump straight to 30 June.

## 6. Which lever did what: indexes alone vs rewrites

The indexes-only run executes the **original** SQL on the indexed database. Comparing the three columns shows whether a query needed its rewrite.

| Query | Before | Original SQL + indexes | Optimized SQL + indexes | What did the work |
|-------|-------:|-----------------------:|------------------------:|-------------------|
| R03, R04, R11, R19, R21, W02, W04, W05 | 18.2, 15.0, 35.3, 5,940.1, 18.8, 17.0, 26.5, 19.1 | 0.140, 0.175, 2.386, 13.091, 0.820, 0.397, 5.056, 0.375 | 0.173, 0.226, 2.553, 13.932, 0.803, 0.396, 6.592, 0.476 | the index alone |
| R09, R16 | 16.3, 19.6 | 7.274, 5.194 | 5.270, 5.586 | the index alone |
| R05 | 11.672 | 0.515 | 0.130 | index + sargable range |
| R08 | 46.566 | 43.657 | 17.038 | rewrite (range + aggregate before join) |
| R12 | 57.608 | 50.745 | 20.421 | rewrite (range) |
| R20 | 15.714 | 16.272 | 3.733 | rewrite (range) |
| R22 | 86.719 | 15.999 | 0.065 | index helps; keyset rewrite finishes it |
| R14, R15 | 53.155, 59.510 | 50.773, 57.129 | 1.252, 0.438 | summary tables |
| R17 | 102.859 | 79.985 | 55.094 | covering index, then compute `age()` once |
| R02, R18 | 0.727, 8.906 | 0.489, 9.902 | 0.100, 5.877 | rewrite |
| R13 | 8.575 (wrong) | 7.637 (wrong) | 1.269 (right) | rewrite (correctness) |

Two observations. **Indexes do nothing for a non-sargable predicate**: R08, R12 and R20 were as slow with the indexes as without until the predicate was rewritten as a range. And **an index cannot make OFFSET cheap**: it only turns "sort 150,000 rows" into "walk 100,025 index entries".

## 7. Write overhead

### 7.1 Benchmark numbers

| Write | Before (ms) | After (ms) | Why |
|-------|------------:|-----------:|-----|
| W01 book | 0.931 | 1.863 | **slower**, see 7.2 |
| W02 check in | 17.019 | 0.396 | the search went from a Seq Scan to an index; the extra index writes for 1 row are invisible |
| W03 prescription follow-up | 0.332 | 0.345 | +4%, within noise; the update now also writes into `ix_presc_followup` |
| W04 nightly NO_SHOW | 26.508 | 6.592 | faster overall, but the writing part got slower, see 7.3 |
| W05 cancel doctor's day | 19.123 | 0.476 | search on `ix_appt_doctor_slot`; 3 rows written |

### 7.2 W01: where the extra time really goes

W01 inserts one row, and that row now goes into 5 indexes on `appointments` instead of 1. We measured where the extra 0.9 ms comes from:

- **The insert itself costs the same once the connection is warm.** 500 bookings in one connection with `pgbench` ([`W01_practo_base.txt`](../benchmarks/results/write_overhead/W01_practo_base.txt), [`W01_practo.txt`](../benchmarks/results/write_overhead/W01_practo.txt)): the `INSERT` statement averages **0.262 ms without the new indexes and 0.263 ms with them**. Four extra B-tree inserts cost microseconds.
- **The first statement in a new connection pays to open the indexes.** `run_benchmark.sh` starts a new `psql` for every run, so every W01 measurement is the first statement of a fresh connection, which must load the definitions of every index on `appointments`. Running W01 twice per connection ([`W01_first_vs_second_in_connection.txt`](../benchmarks/results/write_overhead/W01_first_vs_second_in_connection.txt)): the 1st insert took 0.60-0.76 ms without and 0.94-1.01 ms with the new indexes; the 2nd took 0.16-0.20 ms and 0.20-0.35 ms. The difference is a one-off ~0.3 ms per connection; an application with a connection pool pays it once per connection, not per booking.
- **One outlier**: in run 5 the foreign-key check on `patients` alone took 2.702 ms (its usual time is 0.3-0.7 ms). That trigger does not use any of our indexes, so this is machine noise, and it pulls the 5-run average up (the median is 1.684 ms).

**Acceptable?** Yes. A booking averages 1.9 ms even on a cold connection (target: 5 ms) and about 0.26 ms on a warm one. In exchange, the screens a patient opens before booking became 66-105x faster (R03 slot picker, R04 my appointments).

### 7.3 W04: search vs write

From the plans ([`baseline/W04.txt`](../benchmarks/results/baseline/W04.txt), [`optimized/W04.txt`](../benchmarks/results/optimized/W04.txt)), splitting the `Update` node into finding the rows and writing them:

| | Finding the 329 rows | Writing the 329 rows | Total |
|---|---:|---:|---:|
| Before (avg of 3) | 22.944 ms (Seq Scan) | 3.502 ms | 26.508 ms |
| After (avg of 5) | 0.344 ms (partial index) | 6.190 ms | 6.592 ms |

Writing became **77% more expensive per row**. An `UPDATE` can be HOT (heap-only tuple, no new index entries) only if no indexed column changes. `status` is now part of 4 of the 5 indexes on `appointments` (in the `INCLUDE` lists and in the partial index's `WHERE`), so every status change writes a new entry into all 5 indexes. Measured warm with `pgbench`, W04 went from 15.434 to 4.643 ms per execution ([`W04_practo_base.txt`](../benchmarks/results/write_overhead/W04_practo_base.txt), [`W04_practo.txt`](../benchmarks/results/write_overhead/W04_practo.txt)). **Acceptable**: it is a nightly batch, it is still 4x faster in total, and its target is 1,000 ms.

The same per-row cost applies to W02 and W05 (1 and 3 rows), where it disappears next to the search savings: `pgbench` W02 11.567 → 0.284 ms and W05 11.335 → 0.352 ms.

### 7.4 Maintenance cost of the summary tables

`REFRESH MATERIALIZED VIEW CONCURRENTLY`, 3 runs each ([`mv_refresh.txt`](../benchmarks/results/write_overhead/mv_refresh.txt)): `doctor_rating_summary` 59.7-74.1 ms (avg 67.0), `monthly_medicine_by_specialization` 259.6-319.6 ms (avg 281.2). Run once a night, that is about a third of a second of work, replacing ~110 ms of work on every call of R14 + R15. `CONCURRENTLY` lets readers keep using the old contents during the refresh (it needs the unique index on each view). The cost is staleness: a review written today reaches the ranking tomorrow, which is acceptable for a ranking and for a monthly report.

## 8. Index storage

Measured on a freshly built copy ([`index_sizes.txt`](../benchmarks/results/optimized/index_sizes.txt)):

| Object | Type | On | Size | % of its table | Serves |
|--------|------|----|-----:|---------------:|--------|
| `ix_appt_doctor_slot` | B-tree `(doctor_id, slot_start) INCLUDE (status, consult_ended_at)` | appointments (21 MB) | 8,496 kB | 39.5% | R03, R05, R19, W05 |
| `ix_appt_patient` | B-tree `(patient_id, doctor_id, slot_start) INCLUDE (status)` | appointments | 7,160 kB | 33.3% | R04, R11 |
| `ix_appt_slot_cover` | B-tree `(slot_start, appointment_id) INCLUDE (status, consult_type, patient_id, doctor_id)` | appointments | 8,640 kB | 40.2% | R08, R09, R12, R16, R17, R20, R21, R22, R25, W02 |
| `ix_appt_open_slot_end` | partial B-tree `(slot_end) WHERE status IN ('BOOKED','CHECKED_IN')` | appointments | 40 kB | 0.2% | W04 |
| `ix_presc_followup` | partial B-tree `(follow_up_date) WHERE follow_up_date IS NOT NULL` | prescriptions (7.1 MB) | 224 kB | 3.1% | R11 |
| `ix_patients_allergies` | GIN `(allergies)` | patients (4.2 MB) | 80 kB | 1.9% | R10 |
| `ix_sched_clinic` | B-tree `(clinic_id)` | doctor_schedules (1.8 MB) | 248 kB | 13.8% | R13 (R01, R18, R19) |
| `doctor_rating_summary` | materialized view + unique index | - | 192 kB + 88 kB | - | R14 |
| `monthly_medicine_by_specialization` | materialized view + unique index | - | 304 kB + 248 kB | - | R15 |

- **Database size: 81 MB → 106 MB** (+25 MB, +31%). Almost all of it is the three covering indexes on `appointments` (23.7 MB together, 113% of the table they index). That is the real price of turning the reports into Index Only Scans, and we think it is worth paying: a 2026 report now reads about 3 MB of index instead of 21 MB of table, and storage is the cheapest resource in the system. The partial indexes are nearly free (40 kB and 224 kB) because they index only the rows their query needs.
- B-tree deduplication is not available for indexes with `INCLUDE` columns, so these three are larger than the same keys would be without `INCLUDE`.
- **Bloat seen during the benchmark**: after all benchmark passes, `ix_appt_doctor_slot` had grown from 8.5 to 11 MB and `ix_appt_patient` from 7.2 to 9.6 MB, while `ix_appt_slot_cover` grew only from 8.6 to 8.9 MB. The benchmark's rolled-back W04 runs (329 non-HOT updates each) add index entries that stay until VACUUM; in the doctor- and patient-ordered indexes these land all over the index and split pages, while in the time-ordered index they all land at the end. A point for the maintenance plan in Phase 5.

## 9. Queries we could not speed up (much), and why

| Query | Before → after | Why it stays slow | What we tried |
|-------|----------------|-------------------|---------------|
| **R24** double bookings | 67.173 → 62.321 ms | It has to compare every one of the 135,100 active appointments with every other appointment of the same doctor and slot. Any correct plan reads all of them; the parallel hash join PostgreSQL already uses is close to the cost of a single pass. | Find duplicate groups first, then join back: **110.288 ms** (the hash aggregate over ~135,000 groups spills to disk at `work_mem` = 4 MB). One ordered pass with `lag()` over `ix_appt_doctor_slot`: **79.153 ms** ([`rejected/`](../benchmarks/results/rejected/)). Both rejected. The real fix is to stop double bookings from being created: once the 559 existing pairs are resolved, a partial unique index on `(doctor_id, slot_start) WHERE status <> 'CANCELLED'` (Phase 2, data problem 1) makes R24 return 0 rows forever and lets W01 reject a clash. |
| **R10** allergy conflicts | 45.581 → 41.925 ms | The GIN index finds the 1,737 penicillin-allergic patients without scanning 40,000. But to reach their 6,592 appointments the planner prefers one sequential pass over 150,000 appointments to 1,737 random index probes: with the default `random_page_cost = 4` a random page read is costed 4x a sequential one. On this fully cached table the seq scan is cheap anyway (about 7 ms per worker). | We did not lower `random_page_cost` (a server setting, not allowed). On 20x data the GIN part matters more (800,000 patients). |
| **R25** doctor shopping | 50.801 → 38.699 ms | Needs every completed 2026 appointment (40,670 rows, a third of the table), and `count(DISTINCT ...)` must sort them. The covering index removed the heap reads; the sort remains. | `DISTINCT` triples + `count(*)` instead of `count(DISTINCT)`: **45.303 ms**, rejected. |
| **R17** age groups | 102.859 → 55.094 ms | Same third of the table, and `age()` must still be computed once per appointment. | Replacing `age()` with date arithmetic would be faster but **not** equivalent: interval comparison treats a month as 30 days, so people a day before their birthday can land in a different bucket. We kept `age()`. |
| **R01** find a dermatologist | 4.079 → 4.000 ms | Already uses primary-key indexes on small tables (3,000 doctors). | `EXISTS` instead of `JOIN` + `DISTINCT`: **4.318 ms**, rejected. |
| R06, R07, R23, W03 | sub-millisecond | Already a single unique-index lookup. Their before/after differences (12-17 µs) are measurement noise; the plans are identical. | Nothing to do. |

**Index Only Scans and the visibility map.** In the optimized run, some Index Only Scans on the 2026 range still visited the table for a few hundred rows (R12, R17 and R25: 480 heap fetches per run out of 40,670-51,501 rows), while in the indexes-only run (measured after another `VACUUM`) the same scans had 0. An Index Only Scan can skip the table only for pages the visibility map marks all-visible, and writes clear those marks until the next vacuum. The timings above include these fetches, as measured. On a busy system this means the speed of the covering indexes depends on autovacuum keeping up on `appointments`, which belongs in the Phase 5 maintenance plan.

## 10. Notes on the business logic

- **R21's title says "in-clinic", but the query does not filter `consult_type`.** On this data it makes no difference (every COMPLETED + PENDING appointment is in-clinic: video consultations are always PAID), so we kept the query as it is. We recommend adding `AND consult_type = 'IN_CLINIC'` if video payments can ever be pending.
- **W02 and R22 were ambiguous by design**, not only slow (section 4.3); the tiebreakers fix that.
- **The summary tables are the only objects that need a scheduler** (one nightly job, section 7.4). Everything else is maintained by PostgreSQL itself.

## 11. Reproduce

```bash
# Phase 3 state: schema + data, timezone Asia/Kolkata (docs/03_baseline_timings.md, section 6)
createdb -T practo practo_base                         # keep a copy without the Phase 4 objects
psql -d practo -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
./benchmarks/run_benchmark.sh practo warmup 5 sql/06_optimized_queries.sql && rm -r benchmarks/results/warmup
psql -d practo -c "VACUUM (ANALYZE)"
./benchmarks/run_benchmark.sh practo optimized 5 sql/06_optimized_queries.sql
./benchmarks/compare_results.sh practo_base practo      # proof of identical results
```
