# Practo Doctor Appointments Database: DBMS Project

**Course:** Database Management Systems · **Year:** B.Tech 2nd year · **Team size:** 4
**Database:** PostgreSQL 15 or newer · **Final submission:** Mon 23 Nov 2026
**Topics used:** Data types & constraints · Keys & relationships · Normalization · Query execution plans · Indexing · Query optimization · VACUUM/ANALYZE · Partitioning & sharding

## Files in this folder

| Path | What it is |
|------|------------|
| `README.md` | This project brief |
| `seed_data.zip` | 11 CSV files (150,000 appointments): the only input for Phase 2. Unzip it to get `seed_data/` |
| `queries/workload_30.sql` | The 30 queries for Phase 3 (do not edit) |
| `benchmarks/run_benchmark.sh` | Timing script: 3 runs per query, average, raw plans saved |
| `CHECKPOINTS.md` | Checkpoint dates and the files each one needs (DE and AP repos) |

**Getting started:** **clone this repository and push it into your team's DE repo** (the DE repo you submitted in the form); the steps are in [`CHECKPOINTS.md`](CHECKPOINTS.md). Keep the structure shown in [Repository structure](#repository-structure-submit-exactly-this). Unzip `seed_data.zip` inside your project folder, but don't commit the CSV files. Deadlines are in [`CHECKPOINTS.md`](CHECKPOINTS.md). Then begin with Phase 1.

---

## Team details (fill in before you start)

| Role | Name | Enrollment No. | GitHub Username |
|------|------|----------------|-----------------|
| Group Lead | Aadi Kalra | | RedRangerWentWild |
| Member 2 | Tushar Khemka | | |
| Member 3 | Rudransh Singh | | |
| Member 4 | Abhishek Panigrahi | | |

**Team No.:** T0015 (Bluetrace) · **Section:** E · **Repository URL:** https://github.com/RedRangerWentWild/DE_Project_2026

---

## How this project works

| Phase | What you do | You submit | Counts toward | Marks |
|-------|-------------|------------|---------------|------:|
| 1 | Understand the problem statements | `docs/01_problem_understanding.md` | Query Execution | 2 |
| 2 | Work out the database schema **from the seed data** and load it | `sql/01_schema.sql`, `sql/02_load_data.sql`, `docs/02_schema_design.md` | Query Execution | 5 |
| 3 | Run the **30 given SQL queries** and record their execution time | `docs/03_baseline_timings.md`, `benchmarks/results/baseline/` | Query Execution | 3 |
| 4 | Optimize the queries and record the new times | `sql/05_indexes.sql`, `sql/06_optimized_queries.sql`, `docs/04_optimization_report.md`, `benchmarks/results/optimized/` | Code Optimization | 16 |
| 5 | Scalability test on the **large dataset** (given later by faculty) and final report | `docs/05_scalability_report.md`, `benchmarks/results/large/` | Code Optimization | 14 |
| | **Total** | | | **40** |

---

## Phase 1: Problem statements

Practo lets patients find **doctors** by specialization, city and language, and book a **slot**—either at a **clinic** or as a **video consultation**. Every doctor publishes a weekly **schedule** (which weekdays, which hours, at which clinic, and how long each slot is). Patients check in at the clinic, consult, receive a **prescription** (several medicines with dosage like 1-0-1) and may leave a **review**. Patient records include blood group and **allergies**, so prescriptions can be checked for safety. You have joined the Practo data team.

The current database was put together quickly by an earlier team. It has **no documented schema** (only data exports survive), and the product teams are complaining:

| # | Problem reported | Team | Related queries |
|---|------------------|------|-----------------|
| P1 | "**Doctor search, profiles and the slot picker** are slow—the slot picker builds free slots from the schedule on the fly." | Patient app | R01, R02, R03, R18 |
| P2 | "Patients wait for **My appointments**, sign-in and prescription views; booking a slot lags." | Patient app | R04, R06, R07, W01 |
| P3 | "**Clinic reception** needs the doctor's queue and check-in instantly." | Clinics | R05, W02 |
| P4 | "**Patient safety**: allergy conflicts, missed follow-ups and "doctor shopping" must be found quickly." | Patient safety / Care team | R10, R11, R25, W03 |
| P5 | "Clinic partnerships' "**clinics with no doctor schedule**" list is always **empty**." | Clinic partnerships | R13 |
| P6 | "**Quality** reports (no-shows, waiting time, ratings, double bookings) time out." | Quality | R08, R09, R14, R24, W04 |
| P7 | "Finance, pharmacy and population-health reports are slow, and appointments will grow **20×**." | Finance / Insights | R12, R15, R16, R17, R19, R20, R21, R22, R23, W05 |

**Your job:**
1. Rebuild a correct, well-constrained schema from the data exports (Phase 2).
2. Measure how the 30 most important queries perform today (Phase 3).
3. Make them fast **without changing their results** (Phase 4).
4. Prove the database will survive next year's growth (Phase 5).

**Deliverable for Phase 1** (`docs/01_problem_understanding.md`, at most 1 page):
- For each problem P1–P7, write in your own words what the business needs and which **stakeholder** is affected (patient, doctor, clinic reception, care team, patient-safety team, pharmacy partners, clinic partnerships, finance, support).
- Classify each problem as **customer-facing / real-time** or **reporting / analytics**. This decides your performance targets later.
- List any assumptions you make.

---

## Phase 2: Work out the schema from the seed data

You receive **`seed_data.zip`**. Unzip it to get a folder **`seed_data/`** with 11 CSV files, a real export of the production data:

| File | Rows | What it contains |
|------|-----:|------------------|
| `cities.csv` | 10 | Cities |
| `specializations.csv` | 15 | Medical specializations |
| `doctors.csv` | 3,000 | Doctors |
| `doctor_specializations.csv` | 3,700 | Specializations of each doctor (one is primary) |
| `clinics.csv` | 1,500 | Clinics |
| `doctor_schedules.csv` | 30,499 | Weekly working schedule of each doctor (clinic or video) |
| `patients.csv` | 40,000 | Patients (with blood group and allergies) |
| `appointments.csv` | 150,000 | Every appointment booked from 1 Jan 2025 to 30 Jun 2026 |
| `prescriptions.csv` | 97,234 | Prescriptions written after consultations |
| `prescription_items.csv` | 243,085 | Medicines on each prescription |
| `doctor_reviews.csv` | 30,339 | Patient reviews of consultations |

The first line of every file is the header (column names). Here are the headers and the first rows of each file:

**cities.csv**
```
city_id,city_name,state
1,Bengaluru,Karnataka
2,Mumbai,Maharashtra
```

**specializations.csv**
```
spec_id,spec_name
1,General Physician
2,Dermatologist
```

**doctors.csv**
```
doctor_id,full_name,registration_no,gender,experience_years,consultation_fee,video_fee,languages,is_verified,joined_on
1,Dr. Ananya Gupta,DLMC-010007,M,11,500.00,400.00,"{English,Hindi}",t,2018-01-25
2,Dr. Kavya Khan,GJMC-010014,M,26,1500.00,,"{English,Gujarati,Hindi}",f,2020-07-29
```

**doctor_specializations.csv**
```
doctor_id,spec_id,is_primary
1,8,t
2,15,t
```

**clinics.csv**
```
clinic_id,clinic_name,city_id,locality,latitude,longitude,phone
1,Cloudnine Mumbai 1,2,Navrangpura,19.086856,72.906870,+91-80-0007919
2,Manipal Clinic Hyderabad 2,4,Velachery,17.349476,78.584428,+91-80-0015838
```

**doctor_schedules.csv**
```
doctor_id,weekday,start_time,end_time,clinic_id,slot_minutes
1,1,10:00:00,13:00:00,898,15
1,1,21:00:00,22:00:00,,15
```

**patients.csv**
```
patient_id,full_name,phone,email,dob,gender,blood_group,allergies,city_id,created_at
1,Vivaan Sharma,9400000001,vivaan.sharma1@gmail.com,1995-02-17,F,A-,{Penicillin},2,2024-05-07 09:05:19+05:30
2,Aditya Sharma,9400000002,aditya.sharma2@gmail.com,2014-08-18,F,AB+,,4,2022-01-27 10:53:17+05:30
```

**appointments.csv**
```
appointment_id,patient_id,doctor_id,clinic_id,consult_type,booked_at,slot_start,slot_end,reason,status,checked_in_at,consult_started_at,consult_ended_at,fee,payment_status
1,37976,2846,747,IN_CLINIC,2025-01-01 00:00:00+05:30,2025-01-08 18:15:00+05:30,2025-01-08 18:30:00+05:30,Acne,COMPLETED,2025-01-08 18:01:00+05:30,2025-01-08 19:24:00+05:30,2025-01-08 19:43:00+05:30,1500.00,PAID
2,434,1342,816,IN_CLINIC,2025-01-01 00:05:14+05:30,2025-01-11 10:15:00+05:30,2025-01-11 10:30:00+05:30,Eye irritation,COMPLETED,2025-01-11 10:14:00+05:30,2025-01-11 10:24:00+05:30,2025-01-11 10:30:00+05:30,800.00,PENDING
```

**prescriptions.csv**
```
prescription_id,appointment_id,diagnosis,notes,follow_up_date,issued_at
1,1,Migraine,Plenty of fluids and rest,,2025-01-08 19:45:00+05:30
2,2,Hypertension,,,2025-01-11 10:32:00+05:30
```

**prescription_items.csv**
```
prescription_id,line_no,medicine_name,dosage,duration_days,instructions
1,1,Clindamycin gel,0-0-1,30,At bedtime
1,2,Cetirizine 10 mg,1-0-0,3,After food
```

**doctor_reviews.csv**
```
review_id,appointment_id,rating,recommends,wait_time_bucket,review_text,created_at
1,1,3,t,>1 hr,Prescribed too many medicines,2025-01-11 00:43:00+05:30
2,10,4,t,<15 min,,2025-01-03 20:00:00+05:30
```

Open the files yourself (a spreadsheet, `head`, or `SELECT` after a quick load into a scratch table) and study the data carefully. **Nobody will give you the CREATE TABLE statements.** Working them out *is* the task.

### 2.1 What you must identify (for every table)
1. **Table name and column names.** Use exactly the file names and CSV headers. The 30 queries depend on them.
2. **Data type** of every column. Choose the *right* type, not just `TEXT` everywhere. Think about money, timestamps with a time-zone offset, yes/no columns, small whole numbers, decimals and short codes.
3. **Primary key.** Is it one column, or a combination? (Look closely at `doctor_specializations`, `doctor_schedules` and `prescription_items`. What stops a doctor having two primary specializations?)
4. **Foreign keys.** Which column points to which table? What should happen **ON DELETE** (CASCADE, RESTRICT or SET NULL), and why?
5. **NOT NULL vs NULL.** Some columns are empty in some rows. Find out **when** and **why**, and decide which columns must never be empty. Why do some schedules and appointments have no `clinic_id`? When are `video_fee`, `checked_in_at`, `consult_started_at`, `consult_ended_at`, `follow_up_date`, `allergies` and `blood_group` empty?
6. **UNIQUE** columns (natural candidate keys such as emails, phone numbers, codes and handles).
7. **CHECK constraints.** Write at least **12** that the data obeys and the business needs. Look for formats (registration numbers, dosage like 1-0-1), allowed values (statuses, consult types, payment statuses, blood groups, slot lengths, wait buckets), what type `languages` and `allergies` should be, time order, and rules tying columns together (in-clinic ⇔ clinic, only clinic visits are checked in, refunds only for cancellations).
8. **Relationships and cardinalities** (1:1, 1:N, M:N). Draw the **ER diagram** (image + Mermaid code).
9. **Normal form.** Show that each table is in 3NF/BCNF (list its functional dependencies). Point out any column that is *derived or redundant* (hint: `appointments.fee` vs the doctor's fee for that consult type; `slot_end` vs the schedule's slot length; `doctor_reviews.wait_time_bucket` vs the actual wait) and say whether keeping it is justified.

### 2.2 Rules for your schema
- Create every table in a schema named **`practo`**: `CREATE SCHEMA practo;` and `SET search_path TO practo;`
- In this phase create **only constraints**: PK, FK, UNIQUE, NOT NULL, CHECK. **Do not create any other index yet.** (PostgreSQL automatically indexes PRIMARY KEY and UNIQUE columns; that's allowed. Note which indexes exist.) Your baseline in Phase 3 must reflect a database *without* tuning.
- Your constraints must accept **all** rows of the seed data. If a load fails, either your constraint is wrong or you found a data problem. Explain which in your design doc.

### 2.3 Load the data
Write `sql/02_load_data.sql` using `\copy`, loading tables in the right order (parents before children):

```sql
SET search_path TO practo;
\copy cities FROM 'seed_data/cities.csv' WITH (FORMAT csv, HEADER true)
-- ... the other tables, in an order that satisfies your foreign keys
ANALYZE;
```

Then verify the row counts match the table above, and run at least **3 integrity checks** of your own (e.g. "every appointment falls inside the doctor's schedule for that weekday", "an in-clinic appointment is at a clinic where the doctor works", "no patient is prescribed a medicine they are allergic to"). Paste the results into `docs/02_schema_design.md`.

### Phase 2 deliverables
- `sql/01_schema.sql`: runs top-to-bottom on an empty database without errors
- `sql/02_load_data.sql`: loads all 11 files without errors
- `docs/02_schema_design.md`: data dictionary (table · column · type · constraint · *why*), ER diagram, FDs and normal form per table, integrity-check results, and every data problem you found

---

## Phase 3: Run the 30 queries and record the time

The file **`queries/workload_30.sql`** contains **30 queries**: 25 reads (`R01`–`R25`) and 5 writes (`W01`–`W05`). They're also listed in the [Appendix](#appendix-the-30-queries). **Do not modify them.** If a query fails, your schema doesn't match the seed data; fix the schema, not the query.

### 3.1 How to measure (everyone must use the same method)
- Run each query with `EXPLAIN (ANALYZE, BUFFERS)` and read the **`Execution Time`** at the bottom.
- Run each query **3 times** and record the **average** of the three `Execution Time` values. Keep all three runs in the raw plan file.
- Write queries (`W01`–`W05`) must be measured inside `BEGIN; … ROLLBACK;` so the data does not change.
- Close other heavy applications while measuring, and use the **same laptop** for Phase 3 and Phase 4.

The helper script does all of this for you:
```bash
./benchmarks/run_benchmark.sh <your_database> baseline
# → benchmarks/results/baseline/summary.csv   (avg, median, min, max, scan types)
# → benchmarks/results/baseline/R01.txt …     (full plans of all 3 runs)
```
> ⚠️ One of the 30 queries takes **noticeably longer** than the others on the seed data. That's intentional. Let it finish, and don't skip it.

### 3.2 Deliverable: the timing table
In `docs/03_baseline_timings.md`, fill this table for **all 30** queries:

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Find a doctor: verified dermatologists practising in Bengaluru, most experienced first | READ | | | | |
| R02: Doctor profile: doctor 217's weekly timetable with clinic names | READ | | | | |
| R03: Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026 | READ | | | | |
| R04: "My appointments": patient 90's upcoming appointments | READ | | | | |
| R05: Doctor's queue: doctor 16's appointments on 30 June 2026 | READ | | | | |
| R06: Sign-in with mobile number | READ | | | | |
| R07: Prescription view: the prescription and medicines of appointment 18872 | READ | | | | |
| R08: Quality: no-show rate per specialization in 2026 | READ | | | | |
| R09: Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026) | READ | | | | |
| R10: Patient safety: patients allergic to penicillin who were prescribed amoxicillin | READ | | | | |
| R11: Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet | READ | | | | |
| R12: Product analytics: video vs in-clinic appointments per month in 2026 | READ | | | | |
| R13: Clinic partnerships: clinics where no doctor has any schedule | READ | | | | |
| R14: Doctor ranking: average rating and recommendation rate (at least 10 reviews) | READ | | | | |
| R15: Pharmacy partners: most prescribed medicines per primary specialization in June 2026 | READ | | | | |
| R16: Finance: fees collected per clinic in June 2026 | READ | | | | |
| R17: Population health: completed appointments by patient age group and blood group (2026) | READ | | | | |
| R18: Search filter: Tamil-speaking doctors with Chennai clinics | READ | | | | |
| R19: City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic | READ | | | | |
| R20: Platform analytics: completed appointments per day and running total, June 2026 | READ | | | | |
| R21: Finance: completed in-clinic consultations whose fee is still unpaid | READ | | | | |
| R22: Support console: all appointments, newest first, page 4,001 (25 per page) | READ | | | | |
| R23: Verification team: look up a doctor by medical council registration number | READ | | | | |
| R24: Data quality: two active appointments of the same doctor in the same slot (double bookings) | READ | | | | |
| R25: Care quality: patients who saw 3 or more different doctors of the same specialization in 2026 | READ | | | | |
| W01: Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026 | WRITE | | | | |
| W02: Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026 | WRITE | | | | |
| W03: Doctor: add notes and a follow-up date to the prescription of appointment 18872 | WRITE | | | | |
| W04: Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW | WRITE | | | | |
| W05: Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026 | WRITE | | | | |
| **Total (sum of all 30)** | | | | | |

Below the table, add for each query the **scan type** from the plan (Seq Scan, Index Scan, …) and one line on **why** it is slow or fast.

---

## Phase 4: Optimize the queries

Make the queries faster. **The results must stay the same** (same rows; order matters only where the query has an `ORDER BY`).

### 4.1 Techniques you may use
| Technique | Example |
|-----------|---------|
| B-tree index (single / composite) | the right column **order** matters: equality columns first, then range/sort |
| Partial index | index only the rows a query needs (e.g. a rare status) |
| Covering index | `INCLUDE (...)` so the table is never visited (Index Only Scan) |
| Expression index | index the exact expression used in `WHERE` |
| GIN index | for `ILIKE '%text%'` (extension `pg_trgm`), arrays or full-text search |
| BRIN index | for huge tables stored in time order |
| Query rewrite | sargable date ranges instead of functions on columns; `NOT EXISTS` instead of `NOT IN`; joins instead of correlated subqueries; keyset instead of `OFFSET` pagination; `UNION ALL` instead of `OR` across columns |
| VACUUM / ANALYZE | fresh statistics and visibility maps |
| Summary table / materialized view | for heavy reports that don't need live data (state how it's refreshed) |

**Not allowed:** changing the data, deleting rows, changing PostgreSQL server settings to hide the problem (e.g. huge `work_mem`, `enable_seqscan = off`), or caching results outside the database.

### 4.2 How to work
1. Put every index in `sql/05_indexes.sql`, each with a comment: **which queries it serves and why this type and column order**.
2. Put rewritten queries in `sql/06_optimized_queries.sql`. Copy `queries/workload_30.sql` and change **only** the queries you rewrite, keeping the `-- @R01` markers.
3. **Prove the results are unchanged** for every rewritten query (compare row counts, plus a checksum or an `EXCEPT` query). Put the proof in your report.
4. Benchmark again with the same method:
```bash
./benchmarks/run_benchmark.sh <your_database> optimized 5 sql/06_optimized_queries.sql
```
> 🔎 **Read the results, not just the timings.** At least one of the 30 original queries returns a **wrong answer** because of a subtle SQL rule about NULLs. Find it, explain it, and fix it. This is worth marks.

### 4.3 Deliverable: the optimization table
In `docs/04_optimization_report.md`:

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|-------|------------:|---------------------------|----------------------|-----------:|------------:|:------------:|
| R05 | | e.g. Seq Scan on 150k appointments + DATE() | e.g. index on `appointments(doctor_id, slot_start)` with a sargable range | | e.g. 99% (130×) | ✅ |
| … all 30 … | | | | | | |
| **Total** | | | | | | |

Improvement % = (before − after) / before × 100

Also include:
- **Before/after `EXPLAIN` plans** for your 5 biggest improvements
- **Write overhead:** which write queries got **slower** because of your indexes, by how much, and whether that's acceptable
- **Index storage:** the size of each index you created (`pg_relation_size`) compared with its table
- **Queries you could not speed up**, and why (an honest "this query must read most of the table" earns marks)

---

## Phase 5: Scalability report (large dataset round)

Your optimizations worked on 150,000 appointments. Next year the business expects **20× the volume**.

By **Thu 19 Nov 2026**, faculty will release **`large_data.zip`**: the same 11 CSV files with about **20× the rows** (≈ 3,000,000 appointments, ≈ 4,862,000 prescription items, ≈ 1,945,000 prescriptions, ≈ 800,000 patients, ≈ 610,000 doctor schedules). Until then, work on the design part of the report.

### 5.1 What to do with the large dataset
1. Create a new database. Run **your** `01_schema.sql`, load `large_data/` with your load script (change the folder name only), then run **your** `05_indexes.sql` and `ANALYZE`.
2. Run your **optimized** queries (`sql/06_optimized_queries.sql`). **Do not run the original 30 on the large data.** Some of them could run for a very long time.
   - R22 pages with `OFFSET`; if you replaced it with keyset pagination, explain how the "last seen" value is chosen for the large data.
3. Record the times and compare with your Phase 4 results on the seed data.

| Query | Optimized on seed (ms) | Optimized on large (ms) | Growth (large ÷ seed) | Meets target? | If not, what you changed |
|-------|------------------------:|------------------------:|----------------------:|:-------------:|--------------------------|
| R01 | | | | | |
| … all 30 … | | | | | |

### 5.2 Performance targets on the large dataset
| Query group | Queries | Target (average of 3 runs) |
|-------------|---------|----------------:|
| Real-time / patient and clinic screens | R02, R03, R04, R05, R06, R07, R23, W01, W02, W03 | **under 5 ms** |
| Interactive search and tools | R01, R11, R13, R18, R21, R22, W05 | **under 250 ms** |
| Reports and analytics | R08, R09, R10, R12, R14, R15, R16, R17, R19, R20, R24, R25 | **under 5,000 ms** |
| Batch jobs | W04 | **under 1,000 ms** |

If a query misses its target, **find out why from the plan and fix it.** A query that was fast on the seed data can become slow on large data for reasons that only appear at scale. Show the before/after plans for every fix.

### 5.3 Deliverable: `docs/05_scalability_report.md`
1. **Results table** (above), with every target met or explained.
2. **Growth analysis.** Group your queries by how their time grew when the data grew 20×:
   - *stayed about the same* (why? e.g. index lookups grow with log n)
   - *grew about 20×* (why? e.g. they read a fixed *share* of the table)
   - *grew more than 20×* (why, and what you did about it)
3. **What broke at scale** and how you fixed it (plans before/after).
4. **Storage:** total database size, table vs index size, on seed and large data.
5. **Architecture for 100×:** explain with numbers from your own measurements:
   - **Partitioning:** which table, by which column (RANGE / LIST / HASH), and why. Write the DDL for `appointments`, show partition pruning with `EXPLAIN`, and note the primary-key rule for partitioned tables.
   - **Sharding:** Would you shard by city, by doctor, or by patient? A patient's history spans doctors; a doctor's queue spans patients. Which queries become cross-shard, and how would you handle them?
   - **Read replicas and caching:** which of the 30 queries you would send to a replica or cache, and which must hit the primary.
   - **Maintenance:** VACUUM/autovacuum settings for `appointments`, archiving old data, refreshing summary tables.
6. **Conclusion:** is your database ready for next year? What are the remaining risks?

---

## Repository structure (submit exactly this)

```
practo-dbms-<team-no>/
├── README.md                          # team table, how to run, headline numbers
├── team.json                          # group lead, members, enrollment numbers
├── docs/
│   ├── 01_problem_understanding.md
│   ├── 02_schema_design.md
│   ├── 03_baseline_timings.md
│   ├── 04_optimization_report.md
│   └── 05_scalability_report.md
├── diagrams/
│   └── er_diagram.png
├── sql/
│   ├── 01_schema.sql
│   ├── 02_load_data.sql
│   ├── 05_indexes.sql
│   ├── 06_optimized_queries.sql
│   └── 08_partitioning.sql
├── queries/
│   └── workload_30.sql                # given; do not edit
└── benchmarks/
    ├── run_benchmark.sh               # given
    └── results/
        ├── baseline/                  # Phase 3: summary.csv + raw plans
        ├── optimized/                 # Phase 4
        └── large/                     # Phase 5
```

`team.json`:
```json
{
  "team_number": "",
  "group_lead": { "name": "", "enrollment_no": "", "github": "" },
  "members": [
    { "name": "", "enrollment_no": "", "github": "" },
    { "name": "", "enrollment_no": "", "github": "" },
    { "name": "", "enrollment_no": "", "github": "" }
  ],
  "postgres_version": "",
  "laptop_used_for_benchmarks": ""
}
```

**Do not commit the CSV files** (`seed_data/`, `large_data/`); add them to `.gitignore`. They are too large and we already have them.

---

## Timeline

| Due | Work | Checkpoint |
|-----|------|------------|
| Tue 3 Nov 2026 | Clone this repo into your team's DE repo, add members, commit `team.json` | **CP0** Setup |
| Mon 16 Nov 2026 | Phase 1 + Phase 2 (schema, load, ER, data dictionary) | **CP1** Schema loads all seed data with no errors |
| Tue 17 Nov 2026 | Phase 3 (baseline, 3 runs, average) + start Phase 4 | **CP2** Baseline table for all 30 queries committed |
| Thu 19 Nov 2026 | Phase 4 (indexes, rewrites, wrong-result query) | **CP3** Optimization table committed |
| Mon 23 Nov 2026 | Phase 5 on the large dataset + final report | **CP4 Final submission:** last commit on the default branch |
| Wed 25 – Thu 26 Nov 2026 | Individual analysis, in class time | **CP5** Individual analysis |

Full list of files per checkpoint, including the AP repo: [`CHECKPOINTS.md`](CHECKPOINTS.md).

---

## Evaluation (40 marks)

These 40 marks are the DE part of the project: **Query Execution (10)** and **Code Optimization (30)**.
The AP project (20) and your Individual analysis (40) make up the rest of the 100.

| Phase | Criteria | Marks |
|-------|----------|------:|
| | **Query Execution** | **10** |
| 1 | Problems understood, stakeholders and query groups correctly identified | 2 |
| 2 | Correct data types (1), keys and foreign keys with justified delete rules (1), ≥12 meaningful CHECK / NOT NULL / UNIQUE constraints (1), ER diagram + normal-form analysis (1), data loads cleanly + integrity checks (1) | 5 |
| 3 | All 30 queries measured with the required method: 3 runs, average (1), raw plans committed (1), scan type and reason for each query (1) | 3 |
| | **Code Optimization** | **30** |
| 4 | Speed-up achieved with appropriate techniques (6), every index justified (3), results proven unchanged (2), wrong-result query found and explained (2), write overhead and index storage reported (3) | 16 |
| 5 | Large-dataset results with all targets met or explained (4), growth analysis (3), scale-only problems found and fixed (3), partitioning DDL + sharding/replica design backed by your numbers (4) | 14 |
| | **Total** | **40** |

**Integrity rules**
- Every number in your reports must match the raw plan files in `benchmarks/results/`. Copied or invented timings make the whole phase score 0.
- Every member must have commits; the commit history is checked.
- You may use AI tools to learn, but you must be able to explain every index and rewrite in your individual analysis.

---

## Appendix: the 30 queries

These are identical to `queries/workload_30.sql`. Use the file, not copy-paste from this page.

**R01: Find a doctor: verified dermatologists practising in Bengaluru, most experienced first**
```sql
SELECT DISTINCT d.doctor_id, d.full_name, d.experience_years, d.consultation_fee
FROM doctors d
JOIN doctor_specializations ds ON ds.doctor_id = d.doctor_id
JOIN specializations s         ON s.spec_id = ds.spec_id AND s.spec_name = 'Dermatologist'
JOIN doctor_schedules sc       ON sc.doctor_id = d.doctor_id
JOIN clinics c                 ON c.clinic_id = sc.clinic_id
WHERE c.city_id = 1 AND d.is_verified
ORDER BY d.experience_years DESC
LIMIT 20;
```

**R02: Doctor profile: doctor 217's weekly timetable with clinic names**
```sql
SELECT sc.weekday, sc.start_time, sc.end_time, sc.slot_minutes, coalesce(c.clinic_name, 'Video consultation') AS place
FROM doctor_schedules sc
LEFT JOIN clinics c ON c.clinic_id = sc.clinic_id
WHERE sc.doctor_id = 217
ORDER BY sc.weekday, sc.start_time;
```

**R03: Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026**
```sql
SELECT slot
FROM doctor_schedules sc
CROSS JOIN LATERAL generate_series(('2026-07-03'::date + sc.start_time)::timestamptz,
                                   ('2026-07-03'::date + sc.end_time)::timestamptz - sc.slot_minutes * interval '1 minute',
                                   sc.slot_minutes * interval '1 minute') AS slot
WHERE sc.doctor_id = 217 AND sc.weekday = 5 AND sc.clinic_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM appointments a
                  WHERE a.doctor_id = 217 AND a.slot_start = slot AND a.status <> 'CANCELLED')
ORDER BY slot;
```

**R04: "My appointments": patient 90's upcoming appointments**
```sql
SELECT a.appointment_id, d.full_name, a.consult_type, a.slot_start, c.clinic_name
FROM appointments a
JOIN doctors d ON d.doctor_id = a.doctor_id
LEFT JOIN clinics c ON c.clinic_id = a.clinic_id
WHERE a.patient_id = 90 AND a.status = 'BOOKED'
ORDER BY a.slot_start;
```

**R05: Doctor's queue: doctor 16's appointments on 30 June 2026**
```sql
SELECT a.appointment_id, p.full_name, a.slot_start, a.status, a.checked_in_at
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 16
  AND DATE(a.slot_start) = '2026-06-30'
ORDER BY a.slot_start;
```

**R06: Sign-in with mobile number**
```sql
SELECT patient_id, full_name, dob, blood_group
FROM patients
WHERE phone = '9400000090';
```

**R07: Prescription view: the prescription and medicines of appointment 18872**
```sql
SELECT p.diagnosis, p.follow_up_date, i.line_no, i.medicine_name, i.dosage, i.duration_days, i.instructions
FROM prescriptions p
JOIN prescription_items i ON i.prescription_id = p.prescription_id
WHERE p.appointment_id = 18872
ORDER BY i.line_no;
```

**R08: Quality: no-show rate per specialization in 2026**
```sql
SELECT s.spec_name, count(*) AS appointments,
       round(100.0 * count(*) FILTER (WHERE a.status = 'NO_SHOW') / count(*), 2) AS no_show_pct
FROM appointments a
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
JOIN specializations s         ON s.spec_id = ds.spec_id
WHERE EXTRACT(YEAR FROM a.slot_start) = 2026
  AND a.status IN ('COMPLETED', 'NO_SHOW')
GROUP BY s.spec_name
ORDER BY no_show_pct DESC;
```

**R09: Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026)**
```sql
SELECT a.clinic_id, count(*) AS consults,
       round(avg(EXTRACT(EPOCH FROM (a.consult_started_at - a.slot_start)) / 60), 1) AS avg_wait_min
FROM appointments a
WHERE a.status = 'COMPLETED' AND a.consult_type = 'IN_CLINIC'
  AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
GROUP BY a.clinic_id
HAVING count(*) >= 5
ORDER BY avg_wait_min DESC
LIMIT 20;
```

**R10: Patient safety: patients allergic to penicillin who were prescribed amoxicillin**
```sql
SELECT pt.patient_id, pt.full_name, pt.allergies, i.medicine_name, p.issued_at
FROM patients pt
JOIN appointments a        ON a.patient_id = pt.patient_id
JOIN prescriptions p       ON p.appointment_id = a.appointment_id
JOIN prescription_items i  ON i.prescription_id = p.prescription_id
WHERE pt.allergies @> ARRAY['Penicillin']
  AND i.medicine_name ILIKE '%amoxicillin%'
ORDER BY p.issued_at DESC;
```

**R11: Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet**
```sql
SELECT p.prescription_id, a.patient_id, a.doctor_id, p.follow_up_date
FROM prescriptions p
JOIN appointments a ON a.appointment_id = p.appointment_id
WHERE p.follow_up_date BETWEEN '2026-07-01' AND '2026-07-07'
  AND NOT EXISTS (SELECT 1 FROM appointments f
                  WHERE f.patient_id = a.patient_id AND f.doctor_id = a.doctor_id
                    AND f.slot_start > a.slot_start AND f.status <> 'CANCELLED')
ORDER BY p.follow_up_date;
```

**R12: Product analytics: video vs in-clinic appointments per month in 2026**
```sql
SELECT date_trunc('month', slot_start) AS month, consult_type, count(*) AS appointments
FROM appointments
WHERE EXTRACT(YEAR FROM slot_start) = 2026
GROUP BY 1, 2
ORDER BY 1, 2;
```

**R13: Clinic partnerships: clinics where no doctor has any schedule**
```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE c.clinic_id NOT IN (SELECT sc.clinic_id FROM doctor_schedules sc);
```

**R14: Doctor ranking: average rating and recommendation rate (at least 10 reviews)**
```sql
SELECT a.doctor_id, round(avg(r.rating), 2) AS avg_rating,
       round(100.0 * count(*) FILTER (WHERE r.recommends) / count(*), 1) AS recommend_pct, count(*) AS reviews
FROM doctor_reviews r
JOIN appointments a ON a.appointment_id = r.appointment_id
GROUP BY a.doctor_id
HAVING count(*) >= 10
ORDER BY avg_rating DESC, reviews DESC
LIMIT 20;
```

**R15: Pharmacy partners: most prescribed medicines per primary specialization in June 2026**
```sql
SELECT s.spec_name, i.medicine_name, count(*) AS times_prescribed
FROM prescription_items i
JOIN prescriptions p           ON p.prescription_id = i.prescription_id
JOIN appointments a            ON a.appointment_id = p.appointment_id
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
JOIN specializations s         ON s.spec_id = ds.spec_id
WHERE p.issued_at >= '2026-06-01' AND p.issued_at < '2026-07-01'
GROUP BY s.spec_name, i.medicine_name
ORDER BY s.spec_name, times_prescribed DESC;
```

**R16: Finance: fees collected per clinic in June 2026**
```sql
SELECT c.clinic_id, c.clinic_name, count(*) AS paid_consults, sum(a.fee) AS collected
FROM appointments a
JOIN clinics c ON c.clinic_id = a.clinic_id
WHERE a.payment_status = 'PAID'
  AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
GROUP BY c.clinic_id, c.clinic_name
ORDER BY collected DESC
LIMIT 20;
```

**R17: Population health: completed appointments by patient age group and blood group (2026)**
```sql
SELECT CASE WHEN age(a.slot_start::date, p.dob) < interval '18 years' THEN '0-17'
            WHEN age(a.slot_start::date, p.dob) < interval '40 years' THEN '18-39'
            WHEN age(a.slot_start::date, p.dob) < interval '60 years' THEN '40-59' ELSE '60+' END AS age_group,
       coalesce(p.blood_group, 'unknown') AS blood_group, count(*) AS appointments
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
WHERE a.status = 'COMPLETED' AND a.slot_start >= '2026-01-01'
GROUP BY 1, 2
ORDER BY 1, 2;
```

**R18: Search filter: Tamil-speaking doctors with Chennai clinics**
```sql
SELECT DISTINCT d.doctor_id, d.full_name, d.languages, d.consultation_fee
FROM doctors d
JOIN doctor_schedules sc ON sc.doctor_id = d.doctor_id
JOIN clinics c           ON c.clinic_id = sc.clinic_id
WHERE c.city_id = 5
  AND 'Tamil' = ANY (d.languages)
ORDER BY d.consultation_fee;
```

**R19: City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic**
```sql
SELECT d.doctor_id, d.full_name,
       (SELECT count(*) FROM appointments a WHERE a.doctor_id = d.doctor_id AND a.status = 'COMPLETED'
          AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01') AS june_consults,
       (SELECT max(a.consult_ended_at) FROM appointments a WHERE a.doctor_id = d.doctor_id) AS last_consult_at
FROM doctors d
WHERE EXISTS (SELECT 1 FROM doctor_schedules sc JOIN clinics c ON c.clinic_id = sc.clinic_id
              WHERE sc.doctor_id = d.doctor_id AND c.city_id = 1)
ORDER BY june_consults DESC;
```

**R20: Platform analytics: completed appointments per day and running total, June 2026**
```sql
SELECT day, consults, sum(consults) OVER (ORDER BY day) AS running_total
FROM (
    SELECT slot_start::date AS day, count(*) AS consults
    FROM appointments
    WHERE status = 'COMPLETED'
      AND slot_start::date BETWEEN '2026-06-01' AND '2026-06-30'
    GROUP BY 1
) d
ORDER BY day;
```

**R21: Finance: completed in-clinic consultations whose fee is still unpaid**
```sql
SELECT appointment_id, patient_id, clinic_id, fee, slot_start
FROM appointments
WHERE status = 'COMPLETED' AND payment_status = 'PENDING'
ORDER BY slot_start DESC
LIMIT 100;
```

**R22: Support console: all appointments, newest first, page 4,001 (25 per page)**
```sql
SELECT appointment_id, patient_id, doctor_id, status, slot_start
FROM appointments
ORDER BY slot_start DESC
OFFSET 100000
LIMIT 25;
```

**R23: Verification team: look up a doctor by medical council registration number**
```sql
SELECT doctor_id, full_name, is_verified, joined_on
FROM doctors
WHERE registration_no = 'TSMC-011519';
```

**R24: Data quality: two active appointments of the same doctor in the same slot (double bookings)**
```sql
SELECT a.doctor_id, a.slot_start, a.appointment_id, b.appointment_id AS other_appointment_id
FROM appointments a
JOIN appointments b ON b.doctor_id = a.doctor_id AND b.slot_start = a.slot_start
                   AND b.appointment_id > a.appointment_id
WHERE a.status <> 'CANCELLED' AND b.status <> 'CANCELLED'
ORDER BY a.slot_start DESC;
```

**R25: Care quality: patients who saw 3 or more different doctors of the same specialization in 2026**
```sql
SELECT a.patient_id, ds.spec_id, count(DISTINCT a.doctor_id) AS doctors_seen
FROM appointments a
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
WHERE a.status = 'COMPLETED' AND a.slot_start >= '2026-01-01'
GROUP BY a.patient_id, ds.spec_id
HAVING count(DISTINCT a.doctor_id) >= 3
ORDER BY doctors_seen DESC, a.patient_id;
```

**W01: Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026**
```sql
INSERT INTO appointments (appointment_id, patient_id, doctor_id, clinic_id, consult_type, booked_at, slot_start, slot_end,
                          reason, status, fee, payment_status)
SELECT 90000001, 90, 217, sc.clinic_id, 'IN_CLINIC', '2026-07-01 09:00:00+05:30',
       '2026-07-03 10:30:00+05:30', TIMESTAMPTZ '2026-07-03 10:30:00+05:30' + sc.slot_minutes * interval '1 minute',
       'Skin rash', 'BOOKED', d.consultation_fee, 'PENDING'
FROM doctor_schedules sc JOIN doctors d ON d.doctor_id = sc.doctor_id
WHERE sc.doctor_id = 217 AND sc.weekday = 5 AND sc.start_time = '10:00';
```

**W02: Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026**
```sql
UPDATE appointments
SET status = 'CHECKED_IN', checked_in_at = slot_start - interval '5 minutes'
WHERE appointment_id = (SELECT appointment_id FROM appointments
                        WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC'
                          AND slot_start >= '2026-07-01' AND slot_start < '2026-07-02'
                        ORDER BY slot_start LIMIT 1);
```

**W03: Doctor: add notes and a follow-up date to the prescription of appointment 18872**
```sql
UPDATE prescriptions
SET notes = 'Review blood sugar after 2 weeks', follow_up_date = '2026-07-15'
WHERE appointment_id = 18872;
```

**W04: Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW**
```sql
UPDATE appointments
SET status = 'NO_SHOW'
WHERE status IN ('BOOKED', 'CHECKED_IN')
  AND slot_end < '2026-07-02 00:00:00+05:30'
  AND consult_ended_at IS NULL;
```

**W05: Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026**
```sql
UPDATE appointments
SET status = 'CANCELLED', payment_status = 'REFUNDED'
WHERE doctor_id = 504 AND status = 'BOOKED'
  AND slot_start >= '2026-07-03' AND slot_start < '2026-07-04';
```
