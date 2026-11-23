# Phase 5 - Scalability and Architecture Report (100x Scale)

**Author:** Abhishek Panigrahi (Enrollment: 2501010019, GitHub: Abhishek-047)  
**Team:** T0015 (Bluetrace), Section E  

---

## 1. Executive Summary

In Phases 1 through 4, query execution optimizations (7 indexes, 2 summary tables, and 12 rewritten queries) reduced the 30-workload execution time from **6,747.05 ms** to **290.81 ms** (95.7% latency reduction).

As the application grows from **150,000 appointments** (seed) to **3,000,000** (20x) and eventually **15,000,000 appointments** (100x), physical table size and B-tree index footprints expand beyond available RAM (`shared_buffers`). This report presents the architectural blueprint for handling 100x volume via **Declarative Partitioning**, **Horizontal Sharding**, **Read Replica Topology**, and **Maintenance Automation**.

---

## 2. Growth Analysis (Scaling from Seed to 20x and 100x)

| Query Category | Queries | Seed Latency (Avg) | 20x Projected / Target | Expected Growth Factor | Explanation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Real-time Screens** | R02–R07, R23, W01–W03 | 0.05 – 1.86 ms | **< 5 ms** | $O(\log N)$ (Negligible) | Indexed B-Tree point lookups (`doctor_id`, `patient_id`, `phone`). Increasing $N$ from 150k to 3M only adds 1–2 tree levels. |
| **Interactive Tools** | R01, R11, R13, R18, R21, R22, W05 | 0.06 – 5.88 ms | **< 250 ms** | $O(\log N)$ to $O(K \log N)$ | Keyset pagination (R22) and anti-joins (R11, R13) fetch fixed-size pages ($K \le 100$). |
| **Analytical Reports** | R08, R09, R12, R16, R17, R20, R25 | 3.73 – 55.09 ms | **< 5,000 ms** | Linear $O(N)$ with partition size | Scans a proportional date slice (e.g. June 2026). Partition pruning keeps scan bound to 1 partition. |
| **Batch Sweeps** | W04 (No-show job) | 6.59 ms | **< 1,000 ms** | $O(\text{unclosed bookings})$ | Partial index `ix_appt_open_slot_end` only holds `BOOKED`/`CHECKED_IN` rows (1.2% of total). |

---

## 3. Storage Estimation

| Dataset Tier | Appointments Count | Estimated Table Size | Total Index Size | Combined Working Set |
| :--- | :--- | :--- | :--- | :--- |
| **Seed Data (1x)** | 150,000 | ~22 MB | ~17 MB | ~39 MB (Fits in memory) |
| **Large Data (20x)** | 3,000,000 | ~440 MB | ~340 MB | ~780 MB (Fits in standard `shared_buffers`) |
| **Enterprise Scale (100x)**| 15,000,000 | ~2.2 GB | ~1.7 GB | ~3.9 GB (Requires partitioning + storage tuning) |

---

## 4. Architecture for 100x Volume

### 4.1 Declarative Table Partitioning
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

### 4.2 Horizontal Sharding Strategy
When a single database node reaches CPU or write saturation, horizontal sharding is required.
- **Evaluated Sharding Keys:**
  1. `patient_id`: Separates patients across nodes, but clinic reception queues (R05) and doctor schedules (R03) would require costly cross-shard broadcast queries.
  2. `doctor_id`: Groups doctor appointments on single nodes, but patient histories spanning multiple specialists become distributed queries.
  3. **Recommended Key: `city_id` (Geographic Sharding):**
     - Medical consultations are inherently local (clinics, patients, and doctors predominantly operate within one metropolitan region).
     - Over 90% of patient searches (R01, R18) and clinic check-ins (R05) filter by city or clinic locality.
     - Inter-city queries (such as nationwide video consultations) are routed via PostgreSQL Foreign Data Wrappers (postgres_fdw) or Citus distributed tables.

### 4.3 Read Replica Topology and Caching
- **Primary Database (Read/Write):**
  Handles transactional writes: slot booking (W01), reception check-in (W02), doctor follow-up updates (W03), cancellations (W05), and nightly sweeps (W04).
- **Read Replicas (Streaming Replication):**
  Heavy analytical aggregation queries (R08, R12, R14, R15, R16, R17, R19, R20, R25) are offloaded to asynchronous read replicas to protect OLTP throughput.
- **Caching Layer (Redis):**
  Doctor public profiles (R02, R23) and city/specialization lookup metadata (R01) are cached with a 15-minute TTL.

### 4.4 Maintenance and Autovacuum Tuning
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

## 5. Conclusion
With declarative quarterly partitioning on `slot_start`, read replica routing for heavy reports, and partial B-Tree indexing, the database is architecturally prepared to scale reliably from 150,000 to over 15,000,000 appointments while maintaining sub-5ms latencies on all critical patient and clinic screens.
