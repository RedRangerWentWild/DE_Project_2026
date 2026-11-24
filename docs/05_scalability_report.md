# Phase 5 - Scalability and Architecture Report (100x Scale)

**Author:** Abhishek Panigrahi (Enrollment: 2501010019, GitHub: Abhishek-047)  
**Team:** T0015 (Bluetrace), Section E  

---

## 1. Executive Summary

In Phases 1 through 4, query execution optimizations (7 indexes, 2 summary tables, and 12 rewritten queries) reduced the 30-workload execution time from **6,747.05 ms** to **290.81 ms** (95.7% latency reduction).

As the application grows from **150,000 appointments** (seed) to **3,000,000** (20x) and eventually **15,000,000 appointments** (100x), physical table size and B-tree index footprints expand beyond available RAM (`shared_buffers`). This report presents the architectural blueprint for handling 100x volume via **Declarative Partitioning**, **Horizontal Sharding**, **Read Replica Topology**, and **Maintenance Automation**.

**Measured on the large dataset (section 2).** On the faculty's `large_data.zip` (3,000,000 appointments), all 30 optimized queries meet their Phase 5 targets, with no change to any index or query. For 20x the data, the total of the 30 average times grew 26.0x on the same machine (243.210 ms → 6,321.102 ms); the slowest query is R24, at 2,557.139 ms of its 5,000 ms target.

---

## 2. Measured on the large dataset

All 30 optimized queries meet their Phase 5 targets on the faculty's large dataset (3,000,000 appointments, 20x the seed data), and no index or query had to change for it. The slowest query of each group: real-time W01, 0.862 ms (target 5 ms); interactive R18, 109.411 ms (target 250 ms); report R24, 2,557.139 ms (target 5,000 ms); batch W04, 101.711 ms (target 1,000 ms). Every number in this section comes from [`benchmarks/results/large/`](../benchmarks/results/large/) and is recomputed by [`benchmarks/check_reports.py`](../benchmarks/check_reports.py).

### 2.1 How we measured

- **Data.** `large_data.zip` from the faculty's project repository (release `large-data`), unzipped outside the repository and not committed: 3,000,000 appointments, 4,861,080 prescription items, 1,944,432 prescriptions, 800,000 patients, 609,747 doctor schedules, 608,179 reviews, 60,000 doctors and 30,000 clinics (exact counts in [`sizes.txt`](../benchmarks/results/large/sizes.txt)).
- **Database.** A new database, `practo_large`, with `timezone = Asia/Kolkata`; our `sql/01_schema.sql`; our `sql/02_load_data.sql` with only the folder name changed (`seed_data` → `large_data`); our `sql/05_indexes.sql`; `ANALYZE`. The 11 files loaded in one transaction, with every constraint checked, without an error.
- **Workload.** Our optimized queries: [`workload_large.sql`](../benchmarks/results/large/workload_large.sql) is `sql/06_optimized_queries.sql` with R22's bookmark taken from the large data (section 2.5); nothing else differs. The original 30 queries were not run on the large data, as the brief says.
- **Method.** As in Phases 3 and 4: one warm-up pass, discarded; `VACUUM (ANALYZE)`; then `./benchmarks/run_benchmark.sh practo_large large 3 benchmarks/results/large/workload_large.sql`, i.e. 3 runs per query, the brief's rule for the Phase 5 targets.
- **Machine.** Intel Xeon @ 2.30 GHz, 4 vCPU, 16 GB RAM, Ubuntu 24.04, PostgreSQL 16.15 in its default configuration (`shared_buffers` 128 MB, `work_mem` 4 MB, JIT on). As in Phases 3 and 4, no server setting was changed.
- **Seed and large on the same machine.** This is not the VM of Phases 3 and 4 (Xeon @ 2.10 GHz). So that the growth column measures the data and not the machine, we repeated the Phase 4 measurement on this machine: a fresh seed database built with the same scripts and `sql/05_indexes.sql`, a warm-up pass, `VACUUM (ANALYZE)`, then `sql/06_optimized_queries.sql` with 5 runs, as in Phase 4 ([`large/seed_same_machine/`](../benchmarks/results/large/seed_same_machine/)). This machine is 16% faster: 243.210 ms for the 30 queries, against 290.812 ms in Phase 4. **Growth below is large ÷ seed on the same machine.**

### 2.2 Results table

| Query | Group (target) | Seed, Phase 4 (ms) | Seed, same machine (ms) | Large (ms) | Growth | Meets target? |
|-------|----------------|-------------------:|------------------------:|-----------:|-------:|:-------------:|
| R01 | Interactive (< 250 ms) | 4.000 | 2.733 | 18.321 | 6.7x | Yes |
| R02 | Real-time (< 5 ms) | 0.100 | 0.090 | 0.073 | 0.8x | Yes |
| R03 | Real-time (< 5 ms) | 0.173 | 0.132 | 0.189 | 1.4x | Yes |
| R04 | Real-time (< 5 ms) | 0.226 | 0.214 | 0.086 | 0.4x | Yes |
| R05 | Real-time (< 5 ms) | 0.130 | 0.088 | 0.080 | 0.9x | Yes |
| R06 | Real-time (< 5 ms) | 0.061 | 0.042 | 0.056 | 1.3x | Yes |
| R07 | Real-time (< 5 ms) | 0.124 | 0.076 | 0.068 | 0.9x | Yes |
| R08 | Report (< 5,000 ms) | 17.038 | 13.447 | 365.878 | 27.2x | Yes |
| R09 | Report (< 5,000 ms) | 5.270 | 4.484 | 139.738 | 31.2x | Yes |
| R10 | Report (< 5,000 ms) | 41.925 | 33.690 | 508.470 | 15.1x | Yes |
| R11 | Interactive (< 250 ms) | 2.553 | 2.201 | 26.937 | 12.2x | Yes |
| R12 | Report (< 5,000 ms) | 20.421 | 15.099 | 112.327 | 7.4x | Yes |
| R13 | Interactive (< 250 ms) | 1.269 | 1.037 | 22.998 | 22.2x | Yes |
| R14 | Report (< 5,000 ms) | 1.252 | 1.033 | 15.187 | 14.7x | Yes |
| R15 | Report (< 5,000 ms) | 0.438 | 0.334 | 0.365 | 1.1x | Yes |
| R16 | Report (< 5,000 ms) | 5.586 | 4.551 | 91.364 | 20.1x | Yes |
| R17 | Report (< 5,000 ms) | 55.094 | 51.887 | 1,120.038 | 21.6x | Yes |
| R18 | Interactive (< 250 ms) | 5.877 | 4.908 | 109.411 | 22.3x | Yes |
| R19 | Report (< 5,000 ms) | 13.932 | 10.368 | 381.248 | 36.8x | Yes |
| R20 | Report (< 5,000 ms) | 3.733 | 2.054 | 34.952 | 17.0x | Yes |
| R21 | Interactive (< 250 ms) | 0.803 | 0.776 | 12.666 | 16.3x | Yes |
| R22 | Interactive (< 250 ms) | 0.065 | 0.056 | 0.052 | 0.9x | Yes |
| R23 | Real-time (< 5 ms) | 0.050 | 0.049 | 0.044 | 0.9x | Yes |
| R24 | Report (< 5,000 ms) | 62.321 | 58.819 | 2,557.139 | 43.5x | Yes |
| R25 | Report (< 5,000 ms) | 38.699 | 27.711 | 700.403 | 25.3x | Yes |
| W01 | Real-time (< 5 ms) | 1.863 | 0.877 | 0.862 | 1.0x | Yes |
| W02 | Real-time (< 5 ms) | 0.396 | 0.359 | 0.332 | 0.9x | Yes |
| W03 | Real-time (< 5 ms) | 0.345 | 0.255 | 0.061 | 0.2x | Yes |
| W04 | Batch (< 1,000 ms) | 6.592 | 5.483 | 101.711 | 18.6x | Yes |
| W05 | Interactive (< 250 ms) | 0.476 | 0.357 | 0.046 | 0.1x | Yes |
| **Total of the 30** | | **290.812** | **243.210** | **6,321.102** | **26.0x** | |

Every target is met, so the brief's last column ("if not, what you changed") is empty for all 30 queries: we changed nothing. What changed by itself, in the plans, is in sections 2.3 and 2.4.

Five queries find fewer rows on the large data, because their parameters were picked on the seed data and the large data is a different data set, not 20 copies of it: R04 returns 0 rows instead of 2, R05 1 instead of 3, R07 0 instead of 2, and W03 and W05 change 0 rows instead of 1 and 3 (in the large data, appointment 18872 has no prescription and doctor 504 has no BOOKED appointment on 3 July 2026). Their times are the index lookups that look for these rows, which is the part that depends on the size of the data; for W03 and W05 the time to write the rows is not included. We kept the given parameters rather than choose new ones.

### 2.3 Growth analysis

The data grew 20x. By how the time grew:

**Stayed about the same, 0.1x to 1.4x: R02, R03, R04, R05, R06, R07, R15, R22, R23, W01, W02, W03, W05.** Each one walks down a B-tree to a handful of rows, or stops after a fixed number of rows (R22 after 25, W02 after 1). A walk down a B-tree reads one page per level, and 20x the rows added at most one level ([`sizes.txt`](../benchmarks/results/large/sizes.txt)): the `appointments` indexes these queries use (`appointments_pkey`, `ix_appt_doctor_slot`, `ix_appt_patient`, `ix_appt_slot_cover`) have 3 levels on both data sets, and `uq_patients_phone`, `uq_prescriptions_appointment`, `uq_doctors_registration_no` and `pk_doctor_schedules` went from 2 levels to 3. R15 reads 225 rows of `monthly_medicine_by_specialization`, which has 4,050 rows on both data sets: a summary per month, specialization and medicine does not grow with the number of appointments. The two Phase 4 designs that removed a size-dependent step, the summary table (R15) and keyset pagination (R22), stay flat.

**Grew, but less than 20x, 6.7x to 15.1x.** They return about 20x the rows, but on the large data the planner splits the work over 2 parallel workers, 3 processes in all, where on the seed data it used none (R10: 1).

| Query | Growth | Rows returned by its scans, seed → large | Workers, seed → large | Why |
|-------|-------:|------------------------------------------|-----------------------|-----|
| R01 | 6.7x | `doctors`: 250 → 5,000 | 0 → 2 | 20x the verified dermatologists, found by 3 processes; after the sort, the join to schedules and clinics stops at the 20th doctor (`LIMIT 20`) |
| R12 | 7.4x | `appointments`: 51,501 → 1,029,717 | 0 → 2 | the same index-only scan of 2026, shared by 3 processes |
| R11 | 12.2x | `prescriptions`: 430 → 7,578 | 0 → 2 | the follow-ups due, now found by a parallel bitmap heap scan |
| R10 | 15.1x | `appointments`: 150,000 → 3,000,000 | 1 → 2 | a full scan, with 2 workers instead of 1, plus JIT compilation (`Total 32.425 ms`) |

**Grew about 20x, 14.7x to 25.3x.** They read a fixed share of a table, and the tables grew 20x:

| Query | Growth | Rows returned by its scans, seed → large | Workers, seed → large | Why |
|-------|-------:|------------------------------------------|-----------------------|-----|
| R14 | 14.7x | `doctor_rating_summary`: 1,394 → 28,173 | 0 → 0 | the rating summary has one row per doctor with reviews, so it grew with the doctors |
| R21 | 16.3x | `appointments`: 100 → 100 | 0 → 0 | reads appointments newest first until it has 100 unpaid completed consultations; the rows it passes over first, mostly future bookings, grew with the data (`Rows Removed by Filter: 2361` → `Rows Removed by Filter: 36291`) |
| R20 | 17.0x | `appointments`: 6,863 → 137,597 | 0 → 0 | June 2026's completed appointments, read from `ix_appt_slot_cover` |
| W04 | 18.6x | `appointments`: 329 → 6,239 | 0 → 0 | the bookings to mark as no-shows grew with the data |
| R16 | 20.1x | `appointments`: 6,362 → 127,092; `clinics`: 1,500 → 90,000 | 0 → 2 | parallel, but each of the 3 processes reads all 30,000 clinics for its own hash table |
| R17 | 21.6x | `appointments`: 40,670 → 814,694; `patients`: 40,000 → 800,000 | 0 → 0 | the hash table of the patients no longer fits in `work_mem` and is split into batches on disk (`Batches: 1` → `Batches: 8`) |
| R13 | 22.2x | `clinics`: 1,500 → 30,000 | 0 → 0 | every clinic, each looked up in `ix_sched_clinic` |
| R18 | 22.3x | `doctor_schedules`: 30,499 → 609,747 | 0 → 0 | sequential scans of doctors, schedules and clinics |
| R25 | 25.3x | `appointments`: 40,670 → 814,694 | 0 → 0 | the sort before its `count(DISTINCT ...)` aggregation no longer fits in `work_mem` and goes to disk (`Disk: 17624kB`), plus JIT compilation (`Total 6.246 ms`) |

**Grew more than 20x, 27.2x to 43.5x.** Here something grows faster than the data:

| Query | Growth | Rows returned by its scans, seed → large | Workers, seed → large | Why |
|-------|-------:|------------------------------------------|-----------------------|-----|
| R08 | 27.2x | `appointments`: 44,666 → 894,318 | 0 → 0 | same plan as on the seed data; its hash aggregate per doctor grew more than the scan (`Memory Usage: 369kB` → `Memory Usage: 7953kB`) |
| R09 | 31.2x | `appointments`: 5,622 → 112,014 | 0 → 0 | same plan as on the seed data; its hash aggregate per clinic grew more than the scan (`Memory Usage: 577kB` → `Memory Usage: 7697kB`) |
| R19 | 36.8x | `doctors`: 3,000 → 60,000; `appointments`: 24,960 → 499,200 | 0 → 0 | 20x the doctors with a Bengaluru clinic (`loops=480` → `loops=9600`), each with the same two index-only lookups, plus JIT compilation (`Total 147.450 ms`) |
| R24 | 43.5x | `appointments`: 270,200 → 10,814,727 | 1 → 2 | the plan changed (section 2.4) |

R08 and R09 keep their seed plans; what grows faster than the data is their aggregation. A hash aggregate over 20x the groups needs a hash table of about 8 MB instead of a few hundred kB, and the cost per row of a hash table rises once it no longer fits in the processor's caches. That is the most likely reason: the plans show the larger hash tables, not the cache misses.

### 2.4 What changed at scale

No query missed its target, so nothing had to be fixed. Three things that never happened in the optimized plans on the seed data appear in the large-data plans; they explain the four queries that grew more than 20x, and they are what to watch as the data keeps growing.

**1. R24 changed plan.** On the seed data, the self-join that finds double bookings is a parallel hash join whose hash table fits in memory, in one batch:

`seed_same_machine/R24.txt`, run 5:
```
->  Parallel Hash Join  (cost=5018.01..18005.31 rows=100 width=20) (actual time=26.068..55.841 rows=280 loops=2)
      ->  Parallel Seq Scan on appointments a  (cost=0.00..3822.94 rows=79671 width=16) (actual time=0.004..12.814 rows=67550 loops=2)
      ->  Parallel Hash  (cost=3822.94..3822.94 rows=79671 width=16) (actual time=25.424..25.425 rows=67550 loops=2)
            Buckets: 262144  Batches: 1  Memory Usage: 8416kB
Execution Time: 60.374 ms
```

On the large data there are 20x the active appointments to hash, and the planner switches to a merge join. Both sides are sorted on disk, and the inner side is sorted in full by each of the 3 processes (`loops=3`), which is why the scans of R24 return 40x the rows:

`large/R24.txt`, run 3:
```
->  Merge Join  (cost=674703.14..710238.08 rows=1362 width=20) (actual time=1675.182..2381.172 rows=3769 loops=3)
      ->  Sort  (cost=202038.36..204854.53 rows=1126471 width=16) (actual time=491.733..553.489 rows=901227 loops=3)
            Sort Method: external merge  Disk: 28088kB
      ->  Materialize  (cost=472664.78..486182.44 rows=2703531 width=16) (actual time=1182.808..1573.927 rows=2705551 loops=3)
            ->  Sort  (cost=472664.78..479423.61 rows=2703531 width=16) (actual time=1182.803..1356.112 rows=2702122 loops=3)
                  Sort Method: external merge  Disk: 68800kB
                  ->  Seq Scan on appointments b  (cost=0.00..91433.98 rows=2703531 width=16) (actual time=0.018..317.225 rows=2703682 loops=3)
JIT:
  Timing: Generation 1.901 ms, Inlining 125.707 ms, Optimization 158.145 ms, Emission 106.615 ms, Total 392.367 ms
Execution Time: 2525.744 ms
```

At 2,557.139 ms R24 uses half of its 5,000 ms target, the most of any query, and its sorts grow faster than the data. It is the query to watch.

**2. JIT compilation.** PostgreSQL compiles a plan to machine code when its estimated cost is above `jit_above_cost` (100,000 by default). None of the optimized plans on the seed data got there; on the large data five do, and the compile time is part of their Execution Time: R24 392.367 ms, R19 147.450 ms, R10 32.425 ms, R17 8.603 ms, R25 6.246 ms (run 3 of each). For R19 the compilation is most of the growth beyond 20x; for R24 it is a smaller part than the sorts. JIT is on in the default configuration and we left it on, as in Phases 3 and 4.

**3. Memory.** With the default `work_mem` of 4 MB, the hash join of R17 is split into 8 batches and the sorts of R24 and R25 go to disk; on the seed data all of them fit in memory. The default `shared_buffers` of 128 MB is larger than the whole seed database (107 MB) but a small part of the large one (1,952 MB): R17, R19 and R24 now read pages from outside it (`read=` in their `Buffers` lines), where on the seed data every page they needed was a hit.

### 2.5 R22 on the large data: choosing the bookmark

R22 is keyset pagination (Phase 4): it returns the 25 rows after a bookmark, the last row of the previous page, which the support console takes from the page it just showed. Page 4,001 follows row 100,000 newest first, so on the large data the bookmark is row 100,000 of the large data ([`r22_bookmark.txt`](../benchmarks/results/large/r22_bookmark.txt)):

```sql
SELECT slot_start, appointment_id FROM practo.appointments
ORDER BY slot_start DESC, appointment_id DESC OFFSET 99999 LIMIT 1;   -- (2026-06-19 10:40:00+05:30, 2860103)
```

The seed bookmark, (2025-07-08 12:15:00+05:30, 50125), is not a row of the large data, and 2,000,274 large-data rows come before it: reused, it would show rows 2,000,275 to 2,000,299 instead of page 4,001. With the large-data bookmark, R22 returns exactly the 25 rows of `ORDER BY slot_start DESC, appointment_id DESC OFFSET 100000 LIMIT 25` (0 rows differ), in 0.052 ms: it reads 25 index entries backwards from the bookmark, whatever the page.

### 2.6 Storage, measured

Both databases freshly built, before any benchmark run ([`sizes.txt`](../benchmarks/results/large/sizes.txt)):

| | Seed | Large | Growth |
|---|---:|---:|---:|
| Database | 107 MB | 1,952 MB | 18.3x |
| The 11 tables | 54 MB | 1,066 MB | 19.7x |
| Their indexes | 44 MB | 872 MB | 19.9x |
| `appointments` | 21 MB | 420 MB | 19.7x |
| Indexes on `appointments` | 27 MB | 538 MB | 19.9x |
| The 7 Phase 4 indexes | 24 MB | 483 MB | 19.9x |
| The 2 summary tables, with their indexes | 832 kB | 5,672 kB | 6.8x |

Everything that holds a row per appointment, prescription, patient or doctor grew about 20x, and the indexes kept their proportion to the tables: the indexes on `appointments` are 1.3x the size of the table on both data sets. The summary tables grew 6.8x because one of them, the month × specialization × medicine summary, does not grow at all. The database as a whole grew 18.3x, less than its tables and indexes, because it also holds PostgreSQL's own catalogs, about 8 MB on both data sets. The estimate in section 4 was right for the `appointments` table (about 440 MB; measured 440,287,232 bytes, which `pg_size_pretty` prints as 420 MB) and low for the indexes (about 340 MB; measured 538 MB on `appointments` alone and 872 MB on all tables), and the large database does not fit in the default `shared_buffers` (section 2.4).

---

## 3. Growth Analysis (Scaling from Seed to 20x and 100x)

*Written before the large data was released; the measured growth is in section 2.3.*

| Query Category | Queries | Seed Latency (Avg) | 20x Projected / Target | Expected Growth Factor | Explanation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Real-time Screens** | R02–R07, R23, W01–W03 | 0.05 – 1.86 ms | **< 5 ms** | $O(\log N)$ (Negligible) | Indexed B-Tree point lookups (`doctor_id`, `patient_id`, `phone`). Increasing $N$ from 150k to 3M only adds 1–2 tree levels. |
| **Interactive Tools** | R01, R11, R13, R18, R21, R22, W05 | 0.06 – 5.88 ms | **< 250 ms** | $O(\log N)$ to $O(K \log N)$ | Keyset pagination (R22) and anti-joins (R11, R13) fetch fixed-size pages ($K \le 100$). |
| **Analytical Reports** | R08, R09, R12, R16, R17, R20, R25 | 3.73 – 55.09 ms | **< 5,000 ms** | Linear $O(N)$ with partition size | Scans a proportional date slice (e.g. June 2026). Partition pruning keeps scan bound to 1 partition. |
| **Batch Sweeps** | W04 (No-show job) | 6.59 ms | **< 1,000 ms** | $O(\text{unclosed bookings})$ | Partial index `ix_appt_open_slot_end` only holds `BOOKED`/`CHECKED_IN` rows (1.2% of total). |

---

## 4. Storage Estimation

*Estimated before the large data was released; the measured sizes are in section 2.6.*

| Dataset Tier | Appointments Count | Estimated Table Size | Total Index Size | Combined Working Set |
| :--- | :--- | :--- | :--- | :--- |
| **Seed Data (1x)** | 150,000 | ~22 MB | ~17 MB | ~39 MB (Fits in memory) |
| **Large Data (20x)** | 3,000,000 | ~440 MB | ~340 MB | ~780 MB (Fits in standard `shared_buffers`) |
| **Enterprise Scale (100x)**| 15,000,000 | ~2.2 GB | ~1.7 GB | ~3.9 GB (Requires partitioning + storage tuning) |

---

## 5. Architecture for 100x Volume

### 5.1 Declarative Table Partitioning
- **Target Table:** `appointments` (the primary fact table and hotspot).
- **Partition Scheme:** Range partitioning by `slot_start` on a **Quarterly** basis, 2025 Q1 to 2026 Q4, plus a `DEFAULT` partition for anything outside that range (`sql/08_partitioning.sql`).
- **Mechanism (Partition Pruning):**
  Queries with temporal filters (e.g. `WHERE slot_start >= '2026-06-01' AND slot_start < '2026-07-01'`) are planned against one quarterly partition only; the other seven and the default are pruned during query planning.
- **Seed data per partition:** 22,969 / 24,923 / 25,290 / 25,317 appointments in the four 2025 quarters, 24,665 / 25,013 / 1,823 in 2026 Q1-Q3, and none in the default partition.
- **PostgreSQL Requirement:**
  The partition key (`slot_start`) must be part of the table's Primary Key:
  ```sql
  CONSTRAINT pk_appointments_part PRIMARY KEY (appointment_id, slot_start)
  ```

### 5.2 Horizontal Sharding Strategy
When a single database node reaches CPU or write saturation, horizontal sharding is required.
- **Evaluated Sharding Keys:**
  1. `patient_id`: Separates patients across nodes, but clinic reception queues (R05) and doctor schedules (R03) would require costly cross-shard broadcast queries.
  2. `doctor_id`: Groups doctor appointments on single nodes, but patient histories spanning multiple specialists become distributed queries.
  3. **Recommended Key: `city_id` (Geographic Sharding):**
     - Medical consultations are inherently local (clinics, patients, and doctors predominantly operate within one metropolitan region).
     - Over 90% of patient searches (R01, R18) and clinic check-ins (R05) filter by city or clinic locality.
     - Inter-city queries (such as nationwide video consultations) are routed via PostgreSQL Foreign Data Wrappers (postgres_fdw) or Citus distributed tables.

### 5.3 Read Replica Topology and Caching
- **Primary Database (Read/Write):**
  Handles transactional writes: slot booking (W01), reception check-in (W02), doctor follow-up updates (W03), cancellations (W05), and nightly sweeps (W04).
- **Read Replicas (Streaming Replication):**
  Heavy analytical aggregation queries (R08, R12, R14, R15, R16, R17, R19, R20, R25) are offloaded to asynchronous read replicas to protect OLTP throughput.
- **Caching Layer (Redis):**
  Doctor public profiles (R02, R23) and city/specialization lookup metadata (R01) are cached with a 15-minute TTL.

### 5.4 Maintenance and Autovacuum Tuning
At high insert/update frequencies (e.g., W04 updating thousands of expired appointments to `NO_SHOW`), default autovacuum thresholds trigger too late.
- **Custom Table Settings for `appointments`:**
  ```sql
  ALTER TABLE appointments SET (
      autovacuum_vacuum_scale_factor = 0.05,  -- Trigger vacuum after 5% row changes (instead of 20%)
      autovacuum_vacuum_cost_limit = 2000,
      autovacuum_vacuum_cost_delay = 2
  );
  ```
- **Summary Table Refresh:**
  Nightly cron jobs execute `REFRESH MATERIALIZED VIEW` concurrently for `doctor_rating_summary` and `monthly_medicine_by_specialization`.

---

## 6. Conclusion
With declarative quarterly partitioning on `slot_start`, read replica routing for heavy reports, and partial B-Tree indexing, the database is architecturally prepared to scale reliably from 150,000 to over 15,000,000 appointments while maintaining sub-5ms latencies on all critical patient and clinic screens.

Measured, not only projected: on the large dataset every one of the 30 queries meets its target (section 2), and every real-time screen answers in under 1 ms (the slowest, W01, in 0.862 ms). The risk to watch is R24, the one query whose plan changed at scale: it sorts on disk and uses half of its 5,000 ms target.
