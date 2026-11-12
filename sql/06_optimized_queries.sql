-- =====================================================================
-- Practo Doctor Appointments Database - Phase 4: optimized workload
-- Team T0015 (Bluetrace), Section E
--
-- A copy of queries/workload_30.sql in which ONLY the rewritten queries were
-- changed (R02, R05, R08, R12, R13, R14, R15, R17, R18, R20, R22, W02). Every
-- other query is byte-for-byte the original; it is faster because of
-- sql/05_indexes.sql alone. Each rewrite is preceded by a comment saying what
-- changed and why the result is the same. R13 is the exception on purpose: the
-- original returns a wrong answer (0 rows) and the rewrite returns the right one.
--
-- Run the indexes first (sql/05_indexes.sql). The session time zone must be
-- Asia/Kolkata, as for the original workload.
--
-- Benchmark:  ./benchmarks/run_benchmark.sh practo optimized 5 sql/06_optimized_queries.sql
-- Proof that results are unchanged: docs/04_optimization_report.md, section 4.
-- =====================================================================
SET search_path TO practo;
BEGIN;

-- @R01
-- Find a doctor: verified dermatologists practising in Bengaluru, most experienced first
SELECT DISTINCT d.doctor_id, d.full_name, d.experience_years, d.consultation_fee
FROM doctors d
JOIN doctor_specializations ds ON ds.doctor_id = d.doctor_id
JOIN specializations s         ON s.spec_id = ds.spec_id AND s.spec_name = 'Dermatologist'
JOIN doctor_schedules sc       ON sc.doctor_id = d.doctor_id
JOIN clinics c                 ON c.clinic_id = sc.clinic_id
WHERE c.city_id = 1 AND d.is_verified
ORDER BY d.experience_years DESC
LIMIT 20;

-- @R02
-- Doctor profile: doctor 217's weekly timetable with clinic names
-- REWRITTEN. The LEFT JOIN built a hash table of all 1,500 clinics to look up
-- the clinics of 9 schedule rows. clinic_id is the primary key of clinics, so a
-- LEFT JOIN on it returns at most one name per schedule row: exactly what a
-- scalar subquery returns (or NULL, which coalesce turns into 'Video
-- consultation'). It runs as 9 primary-key lookups, and the schedule rows come
-- out of pk_doctor_schedules already in (weekday, start_time) order, so the
-- sort disappears too.
SELECT sc.weekday, sc.start_time, sc.end_time, sc.slot_minutes,
       coalesce((SELECT c.clinic_name FROM clinics c WHERE c.clinic_id = sc.clinic_id),
                'Video consultation') AS place
FROM doctor_schedules sc
WHERE sc.doctor_id = 217
ORDER BY sc.weekday, sc.start_time;

-- @R03
-- Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026
SELECT slot
FROM doctor_schedules sc
CROSS JOIN LATERAL generate_series(('2026-07-03'::date + sc.start_time)::timestamptz,
                                   ('2026-07-03'::date + sc.end_time)::timestamptz - sc.slot_minutes * interval '1 minute',
                                   sc.slot_minutes * interval '1 minute') AS slot
WHERE sc.doctor_id = 217 AND sc.weekday = 5 AND sc.clinic_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM appointments a
                  WHERE a.doctor_id = 217 AND a.slot_start = slot AND a.status <> 'CANCELLED')
ORDER BY slot;

-- @R04
-- "My appointments": patient 90's upcoming appointments
SELECT a.appointment_id, d.full_name, a.consult_type, a.slot_start, c.clinic_name
FROM appointments a
JOIN doctors d ON d.doctor_id = a.doctor_id
LEFT JOIN clinics c ON c.clinic_id = a.clinic_id
WHERE a.patient_id = 90 AND a.status = 'BOOKED'
ORDER BY a.slot_start;

-- @R05
-- Doctor's queue: doctor 16's appointments on 30 June 2026
-- REWRITTEN. DATE(a.slot_start) = '2026-06-30' hides the column inside a
-- function, so no index on slot_start can be used. The same day as a half-open
-- range on the bare column is sargable and uses ix_appt_doctor_slot
-- (doctor_id = 16 AND slot_start in range). Equivalent because DATE() and the
-- timestamptz literals are both evaluated in the session time zone
-- (Asia/Kolkata): DATE(x) = d  <=>  d <= x < d + 1 day.
SELECT a.appointment_id, p.full_name, a.slot_start, a.status, a.checked_in_at
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 16
  AND a.slot_start >= '2026-06-30' AND a.slot_start < '2026-07-01'
ORDER BY a.slot_start;

-- @R06
-- Sign-in with mobile number
SELECT patient_id, full_name, dob, blood_group
FROM patients
WHERE phone = '9400000090';

-- @R07
-- Prescription view: the prescription and medicines of appointment 18872
SELECT p.diagnosis, p.follow_up_date, i.line_no, i.medicine_name, i.dosage, i.duration_days, i.instructions
FROM prescriptions p
JOIN prescription_items i ON i.prescription_id = p.prescription_id
WHERE p.appointment_id = 18872
ORDER BY i.line_no;

-- @R08
-- Quality: no-show rate per specialization in 2026
-- REWRITTEN (two changes).
-- 1. EXTRACT(YEAR FROM slot_start) = 2026 becomes the range [2026-01-01,
--    2027-01-01): sargable (Index Only Scan on ix_appt_slot_cover) and the
--    planner now estimates the row count correctly (it guessed 57x too low).
-- 2. Aggregate before joining: the 44,666 appointments are first counted per
--    doctor (3,000 groups), and only those 3,000 rows are joined to the primary
--    specialization and re-aggregated. Same totals, because every appointment of
--    a doctor goes to that doctor's single primary specialization (at most one,
--    enforced by uq_ds_one_primary_per_doctor). sum() of bigint returns numeric,
--    so it is cast back to bigint to keep the column type of count(*).
SELECT s.spec_name, sum(x.n)::bigint AS appointments,
       round(100.0 * sum(x.no_show) / sum(x.n), 2) AS no_show_pct
FROM (SELECT a.doctor_id, count(*) AS n,
             count(*) FILTER (WHERE a.status = 'NO_SHOW') AS no_show
      FROM appointments a
      WHERE a.slot_start >= '2026-01-01' AND a.slot_start < '2027-01-01'
        AND a.status IN ('COMPLETED', 'NO_SHOW')
      GROUP BY a.doctor_id) x
JOIN doctor_specializations ds ON ds.doctor_id = x.doctor_id AND ds.is_primary
JOIN specializations s         ON s.spec_id = ds.spec_id
GROUP BY s.spec_name
ORDER BY no_show_pct DESC;

-- @R09
-- Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026)
SELECT a.clinic_id, count(*) AS consults,
       round(avg(EXTRACT(EPOCH FROM (a.consult_started_at - a.slot_start)) / 60), 1) AS avg_wait_min
FROM appointments a
WHERE a.status = 'COMPLETED' AND a.consult_type = 'IN_CLINIC'
  AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
GROUP BY a.clinic_id
HAVING count(*) >= 5
ORDER BY avg_wait_min DESC
LIMIT 20;

-- @R10
-- Patient safety: patients allergic to penicillin who were prescribed amoxicillin
SELECT pt.patient_id, pt.full_name, pt.allergies, i.medicine_name, p.issued_at
FROM patients pt
JOIN appointments a        ON a.patient_id = pt.patient_id
JOIN prescriptions p       ON p.appointment_id = a.appointment_id
JOIN prescription_items i  ON i.prescription_id = p.prescription_id
WHERE pt.allergies @> ARRAY['Penicillin']
  AND i.medicine_name ILIKE '%amoxicillin%'
ORDER BY p.issued_at DESC;

-- @R11
-- Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet
SELECT p.prescription_id, a.patient_id, a.doctor_id, p.follow_up_date
FROM prescriptions p
JOIN appointments a ON a.appointment_id = p.appointment_id
WHERE p.follow_up_date BETWEEN '2026-07-01' AND '2026-07-07'
  AND NOT EXISTS (SELECT 1 FROM appointments f
                  WHERE f.patient_id = a.patient_id AND f.doctor_id = a.doctor_id
                    AND f.slot_start > a.slot_start AND f.status <> 'CANCELLED')
ORDER BY p.follow_up_date;

-- @R12
-- Product analytics: video vs in-clinic appointments per month in 2026
-- REWRITTEN. EXTRACT(YEAR FROM slot_start) = 2026 becomes the equivalent range
-- [2026-01-01, 2027-01-01) (session time zone Asia/Kolkata), so the 51,501 rows
-- are read with an Index Only Scan on ix_appt_slot_cover instead of a full scan,
-- and with a correct row estimate the planner aggregates with a hash table
-- instead of sorting 51,501 rows.
SELECT date_trunc('month', slot_start) AS month, consult_type, count(*) AS appointments
FROM appointments
WHERE slot_start >= '2026-01-01' AND slot_start < '2027-01-01'
GROUP BY 1, 2
ORDER BY 1, 2;

-- @R13
-- Clinic partnerships: clinics where no doctor has any schedule
-- REWRITTEN - WRONG RESULT FIXED (the NULL trap).
-- doctor_schedules.clinic_id is NULL for the 5,899 video blocks. For a clinic
-- with no schedule, "clinic_id NOT IN (..., NULL, ...)" is not TRUE but UNKNOWN,
-- because "x <> NULL" is UNKNOWN, and WHERE keeps only TRUE rows. So the
-- original returns 0 rows whatever the data. NOT EXISTS asks "is there a
-- schedule row for this clinic?", which is only ever TRUE or FALSE, and returns
-- the 292 clinics that really have no schedule. It also runs as an anti-join
-- that probes ix_sched_clinic.
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc WHERE sc.clinic_id = c.clinic_id);

-- @R14
-- Doctor ranking: average rating and recommendation rate (at least 10 reviews)
-- REWRITTEN to read the summary table doctor_rating_summary (sql/05_indexes.sql,
-- refreshed nightly). It holds per doctor: reviews = count(*), avg_rating_exact
-- = avg(rating) unrounded, recommends = count(*) FILTER (WHERE recommends). The
-- output applies the same round() expressions as the original, so the values
-- are identical; HAVING count(*) >= 10 becomes WHERE reviews >= 10.
SELECT doctor_id, round(avg_rating_exact, 2) AS avg_rating,
       round(100.0 * recommends / reviews, 1) AS recommend_pct, reviews
FROM doctor_rating_summary
WHERE reviews >= 10
ORDER BY avg_rating DESC, reviews DESC
LIMIT 20;

-- @R15
-- Pharmacy partners: most prescribed medicines per primary specialization in June 2026
-- REWRITTEN to read the summary table monthly_medicine_by_specialization
-- (sql/05_indexes.sql, refreshed nightly). June 2026 in IST is exactly
-- issued_at >= '2026-06-01' AND issued_at < '2026-07-01' evaluated with
-- timezone = Asia/Kolkata, which is how the summary computes its month.
SELECT spec_name, medicine_name, times_prescribed
FROM monthly_medicine_by_specialization
WHERE month = DATE '2026-06-01'
ORDER BY spec_name, times_prescribed DESC;

-- @R16
-- Finance: fees collected per clinic in June 2026
SELECT c.clinic_id, c.clinic_name, count(*) AS paid_consults, sum(a.fee) AS collected
FROM appointments a
JOIN clinics c ON c.clinic_id = a.clinic_id
WHERE a.payment_status = 'PAID'
  AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
GROUP BY c.clinic_id, c.clinic_name
ORDER BY collected DESC
LIMIT 20;

-- @R17
-- Population health: completed appointments by patient age group and blood group (2026)
-- REWRITTEN. The CASE calls age(slot_start::date, dob) up to three times per row
-- (once per WHEN that is tried), for 40,670 rows. Computing it once in a
-- MATERIALIZED CTE stops the planner from copying the expression back into
-- every WHEN. Grouping the CTE's output also gives the planner a sensible group
-- estimate, so it hashes 36 groups instead of sorting 40,670 rows. The CASE
-- boundaries are compared with the same interval values, so the buckets are
-- exactly the same (we deliberately did not replace age() with date arithmetic:
-- interval comparison treats a month as 30 days, and the edge cases differ).
WITH visits AS MATERIALIZED (
    SELECT age(a.slot_start::date, p.dob) AS age_at_visit, p.blood_group
    FROM appointments a
    JOIN patients p ON p.patient_id = a.patient_id
    WHERE a.status = 'COMPLETED' AND a.slot_start >= '2026-01-01'
)
SELECT CASE WHEN age_at_visit < interval '18 years' THEN '0-17'
            WHEN age_at_visit < interval '40 years' THEN '18-39'
            WHEN age_at_visit < interval '60 years' THEN '40-59' ELSE '60+' END AS age_group,
       coalesce(blood_group, 'unknown') AS blood_group, count(*) AS appointments
FROM visits
GROUP BY 1, 2
ORDER BY 1, 2;

-- @R18
-- Search filter: Tamil-speaking doctors with Chennai clinics
-- REWRITTEN. JOIN + DISTINCT produced 2,880 rows (one per Chennai schedule
-- block) and then sorted them to remove duplicates. "Has at least one schedule
-- at a Chennai clinic" is a semi-join, so EXISTS returns each doctor once with
-- no DISTINCT. Equivalent because doctor_id is the primary key of doctors, so
-- DISTINCT over doctor columns is one row per doctor. ", d.doctor_id" only
-- breaks ties in consultation_fee; the original's DISTINCT already sorted ties
-- by doctor_id, so the output is the same row for row.
SELECT d.doctor_id, d.full_name, d.languages, d.consultation_fee
FROM doctors d
WHERE 'Tamil' = ANY (d.languages)
  AND EXISTS (SELECT 1 FROM doctor_schedules sc
              JOIN clinics c ON c.clinic_id = sc.clinic_id
              WHERE sc.doctor_id = d.doctor_id AND c.city_id = 5)
ORDER BY d.consultation_fee, d.doctor_id;

-- @R19
-- City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic
SELECT d.doctor_id, d.full_name,
       (SELECT count(*) FROM appointments a WHERE a.doctor_id = d.doctor_id AND a.status = 'COMPLETED'
          AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01') AS june_consults,
       (SELECT max(a.consult_ended_at) FROM appointments a WHERE a.doctor_id = d.doctor_id) AS last_consult_at
FROM doctors d
WHERE EXISTS (SELECT 1 FROM doctor_schedules sc JOIN clinics c ON c.clinic_id = sc.clinic_id
              WHERE sc.doctor_id = d.doctor_id AND c.city_id = 1)
ORDER BY june_consults DESC;

-- @R20
-- Platform analytics: completed appointments per day and running total, June 2026
-- REWRITTEN. slot_start::date BETWEEN '2026-06-01' AND '2026-06-30' casts the
-- column, so it is not sargable. The same days as a half-open range on the bare
-- column (session time zone Asia/Kolkata) read June from ix_appt_slot_cover.
-- The ::date in the SELECT list is unchanged, so the days are labelled the same.
SELECT day, consults, sum(consults) OVER (ORDER BY day) AS running_total
FROM (
    SELECT slot_start::date AS day, count(*) AS consults
    FROM appointments
    WHERE status = 'COMPLETED'
      AND slot_start >= '2026-06-01' AND slot_start < '2026-07-01'
    GROUP BY 1
) d
ORDER BY day;

-- @R21
-- Finance: completed in-clinic consultations whose fee is still unpaid
SELECT appointment_id, patient_id, clinic_id, fee, slot_start
FROM appointments
WHERE status = 'COMPLETED' AND payment_status = 'PENDING'
ORDER BY slot_start DESC
LIMIT 100;

-- @R22
-- Support console: all appointments, newest first, page 4,001 (25 per page)
-- REWRITTEN to keyset pagination. OFFSET 100000 sorts and throws away 100,000
-- rows, and gets slower with every page. Keyset pagination remembers the last
-- row of the previous page and starts right after it, using ix_appt_slot_cover
-- (slot_start, appointment_id) backwards: 25 index entries, whatever the page.
-- appointment_id breaks ties: many appointments share a slot_start, and without
-- a tiebreaker "the next page" is not well defined (the original itself can
-- return different rows at the edge of page 4,001, see the report).
-- The bookmark (2025-07-08 12:15:00+05:30, 50125) is the last row of page 4,000
-- in this order; the support console gets it from the page it just showed.
SELECT appointment_id, patient_id, doctor_id, status, slot_start
FROM appointments
WHERE (slot_start, appointment_id) < (TIMESTAMPTZ '2025-07-08 12:15:00+05:30', 50125)
ORDER BY slot_start DESC, appointment_id DESC
LIMIT 25;

-- @R23
-- Verification team: look up a doctor by medical council registration number
SELECT doctor_id, full_name, is_verified, joined_on
FROM doctors
WHERE registration_no = 'TSMC-011519';

-- @R24
-- Data quality: two active appointments of the same doctor in the same slot (double bookings)
SELECT a.doctor_id, a.slot_start, a.appointment_id, b.appointment_id AS other_appointment_id
FROM appointments a
JOIN appointments b ON b.doctor_id = a.doctor_id AND b.slot_start = a.slot_start
                   AND b.appointment_id > a.appointment_id
WHERE a.status <> 'CANCELLED' AND b.status <> 'CANCELLED'
ORDER BY a.slot_start DESC;

-- @R25
-- Care quality: patients who saw 3 or more different doctors of the same specialization in 2026
SELECT a.patient_id, ds.spec_id, count(DISTINCT a.doctor_id) AS doctors_seen
FROM appointments a
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
WHERE a.status = 'COMPLETED' AND a.slot_start >= '2026-01-01'
GROUP BY a.patient_id, ds.spec_id
HAVING count(DISTINCT a.doctor_id) >= 3
ORDER BY doctors_seen DESC, a.patient_id;

-- @W01
-- Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026
INSERT INTO appointments (appointment_id, patient_id, doctor_id, clinic_id, consult_type, booked_at, slot_start, slot_end,
                          reason, status, fee, payment_status)
SELECT 90000001, 90, 217, sc.clinic_id, 'IN_CLINIC', '2026-07-01 09:00:00+05:30',
       '2026-07-03 10:30:00+05:30', TIMESTAMPTZ '2026-07-03 10:30:00+05:30' + sc.slot_minutes * interval '1 minute',
       'Skin rash', 'BOOKED', d.consultation_fee, 'PENDING'
FROM doctor_schedules sc JOIN doctors d ON d.doctor_id = sc.doctor_id
WHERE sc.doctor_id = 217 AND sc.weekday = 5 AND sc.start_time = '10:00';

-- @W02
-- Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026
-- REWRITTEN (determinism, not speed). 11 BOOKED in-clinic appointments share the
-- earliest slot (1 July 10:00), and ORDER BY slot_start alone does not say which
-- one reception should check in, so the original updates whichever row its plan
-- meets first. ", appointment_id" picks the earliest booking among them
-- (first come, first served). It is one of the 11 rows the original may pick,
-- and it is the row the original picks in our baseline and indexed plans
-- (shown in the report). The search uses ix_appt_slot_cover in this exact order.
UPDATE appointments
SET status = 'CHECKED_IN', checked_in_at = slot_start - interval '5 minutes'
WHERE appointment_id = (SELECT appointment_id FROM appointments
                        WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC'
                          AND slot_start >= '2026-07-01' AND slot_start < '2026-07-02'
                        ORDER BY slot_start, appointment_id LIMIT 1);

-- @W03
-- Doctor: add notes and a follow-up date to the prescription of appointment 18872
UPDATE prescriptions
SET notes = 'Review blood sugar after 2 weeks', follow_up_date = '2026-07-15'
WHERE appointment_id = 18872;

-- @W04
-- Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW
UPDATE appointments
SET status = 'NO_SHOW'
WHERE status IN ('BOOKED', 'CHECKED_IN')
  AND slot_end < '2026-07-02 00:00:00+05:30'
  AND consult_ended_at IS NULL;

-- @W05
-- Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026
UPDATE appointments
SET status = 'CANCELLED', payment_status = 'REFUNDED'
WHERE doctor_id = 504 AND status = 'BOOKED'
  AND slot_start >= '2026-07-03' AND slot_start < '2026-07-04';

-- @END
ROLLBACK;
