# Phase 3 - Baseline timings

**Team T0015 (Bluetrace), Section E**

All 30 queries from `queries/workload_30.sql` were run, unchanged, against the Phase 2 schema with no tuning indexes. Every number below comes from the raw plan files in [`benchmarks/results/baseline/`](../benchmarks/results/baseline/) (`R01.txt` ... `W05.txt`, three runs each) and from [`summary.csv`](../benchmarks/results/baseline/summary.csv).

## 1. How we measured

| Item | Value |
|------|-------|
| Command | `./benchmarks/run_benchmark.sh practo baseline` (the given script, unmodified) |
| Method | `EXPLAIN (ANALYZE, BUFFERS)`, **3 runs per query**, average of the three `Execution Time` values. Write queries run inside `BEGIN; ... ROLLBACK;`, so the data never changed. |
| Cache state | One full pass of the workload was run first and thrown away, so every query was measured with a warm cache. In the 90 measured runs no data page was read from disk (`shared read` never appears in the plans, every access is a `shared hit`); the only disk I/O in the whole baseline is R22's sort spilling to a temporary file. The numbers therefore measure work done in memory, not disk speed. Phase 4 uses the same procedure, so before and after are comparable. |
| Database state | Fresh load of the seed data (`sql/01_schema.sql` + `sql/02_load_data.sql`), followed by autovacuum's own pass over every table (we waited for it and did not run `VACUUM` by hand). Only the indexes created by PRIMARY KEY / UNIQUE constraints exist (list in `docs/02_schema_design.md`, section 7). Database size 81 MB. |
| Server | PostgreSQL **16.15** (Ubuntu package `16.15-0ubuntu0.24.04.1`), **default configuration**: `shared_buffers` 128 MB, `work_mem` 4 MB, `random_page_cost` 4, `jit` on, `max_parallel_workers_per_gather` 2. Only `timezone` was set, to `Asia/Kolkata` at database level (`ALTER DATABASE practo SET timezone TO 'Asia/Kolkata'`), because `DATE(slot_start)`, `slot_start::date`, `EXTRACT(YEAR ...)` and the date literals in R03, R05, R08, R12, R17, R20, W02 and W05 are evaluated in the session time zone (see `docs/01_problem_understanding.md`, assumption 1). |
| Machine | Linux virtual machine: Intel Xeon @ 2.10 GHz, 4 vCPU, 16 GB RAM, Ubuntu 24.04. Phase 4 is measured on the same machine. |

## 2. Timing table

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Find a doctor: verified dermatologists practising in Bengaluru, most experienced first | READ | 4.083 | 5.490 | 2.663 | 4.079 |
| R02: Doctor profile: doctor 217's weekly timetable with clinic names | READ | 0.705 | 0.776 | 0.699 | 0.727 |
| R03: Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026 | READ | 16.074 | 23.272 | 15.305 | 18.217 |
| R04: "My appointments": patient 90's upcoming appointments | READ | 13.750 | 17.767 | 13.401 | 14.973 |
| R05: Doctor's queue: doctor 16's appointments on 30 June 2026 | READ | 13.307 | 11.816 | 9.893 | 11.672 |
| R06: Sign-in with mobile number | READ | 0.049 | 0.048 | 0.051 | 0.049 |
| R07: Prescription view: the prescription and medicines of appointment 18872 | READ | 0.115 | 0.143 | 0.164 | 0.141 |
| R08: Quality: no-show rate per specialization in 2026 | READ | 41.567 | 53.754 | 44.378 | 46.566 |
| R09: Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026) | READ | 14.968 | 16.592 | 17.362 | 16.307 |
| R10: Patient safety: patients allergic to penicillin who were prescribed amoxicillin | READ | 44.460 | 47.304 | 44.978 | 45.581 |
| R11: Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet | READ | 35.705 | 34.796 | 35.358 | 35.286 |
| R12: Product analytics: video vs in-clinic appointments per month in 2026 | READ | 60.037 | 61.360 | 51.426 | 57.608 |
| R13: Clinic partnerships: clinics where no doctor has any schedule | READ | 8.237 | 10.742 | 6.745 | 8.575 |
| R14: Doctor ranking: average rating and recommendation rate (at least 10 reviews) | READ | 53.799 | 52.818 | 52.847 | 53.155 |
| R15: Pharmacy partners: most prescribed medicines per primary specialization in June 2026 | READ | 58.893 | 60.282 | 59.354 | 59.510 |
| R16: Finance: fees collected per clinic in June 2026 | READ | 18.942 | 19.675 | 20.245 | 19.621 |
| R17: Population health: completed appointments by patient age group and blood group (2026) | READ | 122.429 | 107.049 | 79.099 | 102.859 |
| R18: Search filter: Tamil-speaking doctors with Chennai clinics | READ | 8.494 | 8.768 | 9.455 | 8.906 |
| R19: City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic | READ | 6,180.775 | 6,073.673 | 5,565.739 | **5,940.062** |
| R20: Platform analytics: completed appointments per day and running total, June 2026 | READ | 15.267 | 15.904 | 15.971 | 15.714 |
| R21: Finance: completed in-clinic consultations whose fee is still unpaid | READ | 17.403 | 21.238 | 17.671 | 18.771 |
| R22: Support console: all appointments, newest first, page 4,001 (25 per page) | READ | 96.195 | 87.132 | 76.830 | 86.719 |
| R23: Verification team: look up a doctor by medical council registration number | READ | 0.069 | 0.069 | 0.062 | 0.067 |
| R24: Data quality: two active appointments of the same doctor in the same slot (double bookings) | READ | 65.096 | 64.553 | 71.871 | 67.173 |
| R25: Care quality: patients who saw 3 or more different doctors of the same specialization in 2026 | READ | 43.370 | 58.830 | 50.203 | 50.801 |
| W01: Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026 | WRITE | 0.803 | 1.137 | 0.852 | 0.931 |
| W02: Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026 | WRITE | 16.324 | 20.631 | 14.101 | 17.019 |
| W03: Doctor: add notes and a follow-up date to the prescription of appointment 18872 | WRITE | 0.306 | 0.357 | 0.334 | 0.332 |
| W04: Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW | WRITE | 26.823 | 24.653 | 28.049 | 26.508 |
| W05: Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026 | WRITE | 20.530 | 17.364 | 19.476 | 19.123 |
| **Total (sum of all 30)** | | **6,998.575** | **6,917.993** | **6,324.582** | **6,747.052** |

The averages are exactly the `avg_ms` column of `summary.csv`; the run columns are the three `Execution Time` lines of each raw file. R19 is the query the brief warns about: it alone is **88.0%** of the total. The other 29 queries add up to 807 ms.

## 3. Scan type and why each query is slow or fast

Scan types are taken from the last run's plan (`scan_nodes` in `summary.csv`). "Rows read" means rows the plan had to look at; "rows returned" is the final result.

| Query | Scan types in the plan | Avg (ms) | Why it is slow or fast |
|-------|------------------------|---------:|------------------------|
| R01 | Seq Scan `specializations`, `doctor_specializations`, `clinics`; Index Scan `doctors_pkey`, `pk_doctor_schedules` | 4.079 | **Fast**: every table is small and the per-doctor lookups use primary-key indexes. Wasted work: the join produces 366 rows (one per Bengaluru schedule block) that are sorted and de-duplicated just to return 20 doctors. |
| R02 | Index Scan `pk_doctor_schedules`; Seq Scan `clinics` | 0.727 | **Fast**, but about 0.55 ms of the 0.7 ms is building a hash table of all 1,500 clinics to look up the clinics of 9 schedule rows, plus a sort the primary-key order already provides. |
| R03 | Index Scan `pk_doctor_schedules`; **Seq Scan `appointments`** | 18.217 | **Slow for a real-time screen.** The `NOT EXISTS` needs doctor 217's appointments; with no index on `appointments.doctor_id` it reads all 150,000 rows to find 72, then a Merge Anti Join removes booked slots. |
| R04 | **Seq Scan `appointments`**; Index Scan `doctors_pkey`; Seq Scan `clinics` | 14.973 | **Slow**: no index on `appointments.patient_id`, so 150,000 rows are read to return 2. The cost grows with the whole table, although the answer is about one patient. |
| R05 | **Parallel Seq Scan `appointments`**; Index Scan `patients_pkey` | 11.672 | **Slow**: `DATE(a.slot_start) = '2026-06-30'` wraps the column in a function, so it is not sargable (no index on `slot_start` could be used even if it existed), and there is no index on `doctor_id`. A parallel worker is started to find 3 rows. |
| R06 | Index Scan `uq_patients_phone` | 0.049 | **Fast**: the UNIQUE constraint's index finds the patient in 3 buffer reads. |
| R07 | Index Scan `uq_prescriptions_appointment`, `pk_prescription_items` | 0.141 | **Fast**: both steps use constraint indexes; the composite key `(prescription_id, line_no)` returns the lines already in order. |
| R08 | **Parallel Seq Scan `appointments`**; Seq Scan `doctor_specializations`, `specializations` | 46.566 | **Reads a third of the table by design** (44,666 rows of 2026). `EXTRACT(YEAR FROM slot_start) = 2026` is not sargable and has no statistics, so the planner estimated 392 rows per worker instead of 22,333 (57x too low), then sorted 44,666 rows to group 15 specializations. |
| R09 | **Parallel Seq Scan `appointments`** | 16.307 | **Slow for what it needs**: the June range is sargable, but with no index on `slot_start` all 150,000 rows are read to aggregate 5,622. |
| R10 | Seq Scan `patients`; **Parallel Seq Scan `appointments`**; Index Scan `uq_prescriptions_appointment`, `pk_prescription_items` | 45.581 | **Slow**: the 1,737 penicillin-allergic patients are found by scanning 40,000 patients, then hash-joined to all 150,000 appointments (no index on `patient_id`) to reach 6,592 appointments, followed by 6,592 + 4,318 index lookups. |
| R11 | Seq Scan `prescriptions`; **Seq Scan `appointments`**; Index Scan `appointments_pkey` | 35.286 | **Slow**: 97,234 prescriptions are scanned for 430 July follow-ups (no index on `follow_up_date`), and the `NOT EXISTS` runs as a Hash Anti Join that hashes 135,100 non-cancelled appointments to check 430 patient-doctor pairs. |
| R12 | **Seq Scan `appointments`** | 57.608 | **Reads a third of the table**, made worse by `EXTRACT(YEAR ...)`: estimated 750 rows, actually 51,501, so the planner sorts 51,501 rows (3.7 MB) to build 14 groups. |
| R13 | Seq Scan `clinics`; Seq Scan `doctor_schedules` (hashed SubPlan) | 8.575 | **Fast but wrong: returns 0 rows.** `NOT IN` over a subquery that contains NULL (the 5,899 video blocks) is never TRUE, so the filter removes all 1,500 clinics. 292 clinics really have no schedule. Fixed in Phase 4. |
| R14 | **Seq Scan `appointments`**, Seq Scan `doctor_reviews` | 53.155 | **Reads everything by design**: all 30,339 reviews are hash-joined to all 150,000 appointments only to learn each review's `doctor_id`, then 3,000 doctors are aggregated. |
| R15 | **Parallel Seq Scan `prescription_items`** (243k), Seq Scans `appointments`, `prescriptions`, `doctor_specializations`, `specializations` | 59.510 | **Slow**: no index on `prescriptions.issued_at`, so 97,234 prescriptions are scanned for 5,503 June ones, and the joins to items and appointments are hash joins over the full tables. |
| R16 | **Seq Scan `appointments`**; Seq Scan `clinics` | 19.621 | **Slow for what it needs**: 150,000 rows read for 6,362 June PAID rows (no index on `slot_start`). |
| R17 | **Seq Scan `appointments`**; Seq Scan `patients` | 102.859 | **Reads a third of the table by design**: 40,670 completed 2026 appointments joined to all 40,000 patients. The `CASE` calls `age()` up to three times per row, and the planner expected 41,907 groups (actual 36), so it sorts 40,670 rows instead of hashing. Also the noisiest query (79-122 ms). |
| R18 | Seq Scan `doctors`, `doctor_schedules`, `clinics` | 8.906 | **Medium**: `'Tamil' = ANY (languages)` is tested on all 3,000 doctors and the join produces 2,880 rows (one per Chennai schedule block) that `DISTINCT` reduces to 360 doctors. |
| R19 | Seq Scan `doctors`, `doctor_schedules`, `clinics`; **SubPlan 1 and SubPlan 2 = Seq Scan `appointments`, each executed 480 times** | **5,940.062** | **The slow query.** The two correlated subqueries run once per Bengaluru doctor (480), and each run is a full scan of 150,000 appointments: 960 scans = 144 million rows and 2.6 million buffer hits (about 20 GB of 8 kB pages) per execution. The plan's estimated cost (30.9 million) also triggers JIT compilation, which costs 221-244 ms per run on its own. |
| R20 | **Parallel Seq Scan `appointments`** | 15.714 | **Slow for what it needs**: `slot_start::date BETWEEN ...` casts the column, so it is not sargable; estimated 358 rows per worker, actually 3,432. |
| R21 | **Parallel Seq Scan `appointments`** + top-N heapsort | 18.771 | **Slow for what it needs**: 150,000 rows read, 24,683 completed-but-pending kept, sorted only to return the newest 100. |
| R22 | **Seq Scan `appointments`** + Sort (external merge, 6.2 MB on disk) | 86.719 | **Slow and gets slower with every page**: `OFFSET 100000` means sorting all 150,000 rows and throwing away 100,000. The sort does not fit in `work_mem` (4 MB) and spills to disk. |
| R23 | Index Scan `uq_doctors_registration_no` | 0.067 | **Fast**: UNIQUE index lookup. |
| R24 | **Parallel Seq Scan `appointments` (twice)** + Parallel Hash Join | 67.173 | **Reads everything twice by design**: a self-join of all 135,100 non-cancelled appointments on `(doctor_id, slot_start)`; the hash table holds every row (8.4 MB) to find 559 pairs. Every row also matches itself, so 135,659 joined rows (135,100 self-matches + 559 reversed pairs) are thrown away by `b.appointment_id > a.appointment_id`. |
| R25 | **Seq Scan `appointments`**; Seq Scan `doctor_specializations` | 50.801 | **Reads a third of the table by design**: 40,670 completed 2026 rows are sorted on `(patient_id, spec_id, doctor_id)` because `count(DISTINCT ...)` needs sorted input. |
| W01 | Index Scan `pk_doctor_schedules`, `doctors_pkey` | 0.931 | **Fast**: both lookups are indexed. More than half of the time is the three foreign-key checks on `patients`, `doctors` and `clinics` (the `Trigger for constraint fk_appt_*` lines: 0.51 of 0.85 ms in run 3). |
| W02 | **Seq Scan `appointments`**; Index Scan `appointments_pkey` | 17.019 | **Slow for a desk action**: finding the earliest BOOKED in-clinic slot of 1 July reads all 150,000 rows (227 candidates) and sorts them; only the update itself uses an index. |
| W03 | Index Scan `uq_prescriptions_appointment` | 0.332 | **Fast**: the UNIQUE index on `prescriptions.appointment_id` finds the one row. |
| W04 | **Seq Scan `appointments`** | 26.508 | **Slow for 329 rows**: no index can serve `status IN ('BOOKED','CHECKED_IN')` + `slot_end`, so all 150,000 rows are read; the 329 updates themselves are cheap. |
| W05 | **Seq Scan `appointments`** | 19.123 | **Slow for 3 rows**: no index on `doctor_id`, so 150,000 rows are read to cancel 3 appointments. |

## 4. What the baseline tells us

1. **One table, one missing kind of index.** 21 of the 30 plans contain a sequential scan of `appointments`. The table has exactly one index (its primary key); none of its three foreign-key columns (`patient_id`, `doctor_id`, `clinic_id`) and neither time column is indexed. Every "one patient", "one doctor" or "one day" question therefore costs a full read of 150,000 rows, and will cost a full read of 3,000,000 rows next year.
2. **Four predicates hide the column inside an expression**: `DATE(slot_start)` (R05), `EXTRACT(YEAR FROM slot_start)` (R08, R12) and `slot_start::date` (R20). An index on `slot_start` cannot be used for them, and the planner also misjudges how many rows they return (57-69x too low for R08 and R12), which leads to poor plan choices such as sorting instead of hashing.
3. **Correlated subqueries are not slow by themselves; correlated subqueries over a sequential scan are.** R19 is a nested loop with 480 outer rows whose inner side is a full table scan, so its cost is (number of Bengaluru doctors) x (number of appointments). It is 88% of the whole workload. If both grow 20x on the large dataset, the same plan grows about 400x: from 6 seconds to roughly 40 minutes.
4. **Several queries must read a large share of the table whatever we do**: R08, R12, R17 and R25 need every 2026 appointment, R14 every review and R24 every active appointment. Indexes alone will not make these near-instant; they will need narrower access paths, better plans or a summary table.
5. **The writes are slowed down by the same missing indexes**: W02, W04 and W05 change 1, 329 and 3 rows but read 150,000 rows to find them. W01 and W03 are already fast and are the ones most likely to get slightly slower once we add indexes in Phase 4 (more index entries to write). We will measure that.
6. **Correctness, not speed**, for R13: it returns 0 rows instead of 292 (NULL inside `NOT IN`; already noted in `docs/02_schema_design.md`, data problem 5).

## 5. Things we noticed in the results (used in Phase 4)

- **Ties at a LIMIT/OFFSET boundary make some answers depend on the plan.** R14 (positions 19-21 all have average 4.42 with 12 reviews), R16 (positions 19-21 all collected 10,600.00), R21 (positions 99-104+ all at 29 June 10:30), R22 (positions 99,997-100,001 all at 8 July 2025 12:15) and W02 (11 BOOKED in-clinic appointments share the earliest slot, 1 July 10:00). Their `ORDER BY` does not decide between the tied rows, so even the original query may return a different one of them if its plan changes. Phase 4 has to prove "same result" with this in mind.
- **R21's title says "in-clinic" but the query has no `consult_type` filter.** On this data it makes no difference: all 24,683 COMPLETED + PENDING appointments are in-clinic (video consultations are always PAID). We keep the query unchanged and note it for the Finance team.
- **W02 picks one of 11 patients arbitrarily** ("the earliest BOOKED appointment" has 11 candidates at 10:00). That is a business ambiguity, not only a performance problem.

## 6. Reproduce

```bash
createdb practo
psql -d practo -c "ALTER DATABASE practo SET timezone TO 'Asia/Kolkata'"
unzip seed_data.zip
psql -d practo -v ON_ERROR_STOP=1 -f sql/01_schema.sql
psql -d practo -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
# wait about a minute for autovacuum, then: one warm-up pass (discard it), then the measured pass
./benchmarks/run_benchmark.sh practo warmup && rm -r benchmarks/results/warmup
./benchmarks/run_benchmark.sh practo baseline
```

Timings on another machine will differ in absolute terms. Phase 3 and Phase 4 must be measured on the same machine; if the team re-measures on another laptop, both commands have to be run again there.
