-- =====================================================================
-- Practo Doctor Appointments Database - Phase 4 indexes
-- Team T0015 (Bluetrace), Section E
--
-- Run after sql/01_schema.sql and sql/02_load_data.sql:
--     psql -d practo -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
--
-- 7 indexes + 2 summary tables (materialized views). Every object says which
-- of the 30 queries it serves and why it has this type and column order.
-- The reasoning and the measured effect are in docs/04_optimization_report.md.
--
-- Design rules we followed
--   * Equality columns first, then the range / ORDER BY column.
--   * INCLUDE the few extra columns a query reads, so it becomes an Index Only
--     Scan (no heap access), but only when that query is hot or reads many rows.
--   * One index should serve several queries; every extra index on
--     `appointments` makes every INSERT/UPDATE of that table slower.
--   * No expression indexes on DATE(slot_start), slot_start::date or
--     EXTRACT(YEAR FROM slot_start): those functions depend on the session time
--     zone, so PostgreSQL refuses to index them (they are STABLE, not
--     IMMUTABLE). Those queries are rewritten into plain ranges on slot_start
--     instead (sql/06_optimized_queries.sql).
-- =====================================================================
SET search_path TO practo;

-- ---------------------------------------------------------------------
-- 1. One doctor's appointments, in time order
--    Serves: R03 (free slots of doctor 217), R05 (doctor 16's queue on one
--    day), R19 (both correlated subqueries, once per Bengaluru doctor),
--    W05 (cancel doctor 504's day).
--    Order: doctor_id is always an equality, slot_start is the range or the
--    lookup value, so (doctor_id, slot_start).
--    INCLUDE (status, consult_ended_at): R03 and R19 filter on status, and R19
--    takes max(consult_ended_at) per doctor. With both columns in the index the
--    960 lookups R19 makes are Index Only Scans and never touch the table.
--    Also indexes the foreign key appointments.doctor_id.
-- ---------------------------------------------------------------------
CREATE INDEX ix_appt_doctor_slot
    ON appointments (doctor_id, slot_start)
    INCLUDE (status, consult_ended_at);

-- ---------------------------------------------------------------------
-- 2. One patient's appointments, per doctor, in time order
--    Serves: R04 (patient 90's upcoming appointments) and R11 (has this patient
--    booked a later appointment with the same doctor? - the NOT EXISTS probe).
--    Order: R11's probe is patient_id = ? AND doctor_id = ? AND slot_start > ?,
--    i.e. two equalities then a range, so (patient_id, doctor_id, slot_start).
--    R04 only knows patient_id, which is the leading column, so it can use the
--    same index.
--    INCLUDE (status): the probe also checks status <> 'CANCELLED', so it stays
--    an Index Only Scan.
--    Also indexes the foreign key appointments.patient_id.
-- ---------------------------------------------------------------------
CREATE INDEX ix_appt_patient
    ON appointments (patient_id, doctor_id, slot_start)
    INCLUDE (status);

-- ---------------------------------------------------------------------
-- 3. All appointments in time order (covering index for the reports)
--    Serves: R08, R12, R17, R20, R25 (2026 / June ranges, read as Index Only
--    Scans), R09, R16 (June ranges), R21 (newest completed-but-unpaid first),
--    R22 (newest first, keyset pagination), W02 (earliest booking on 1 July).
--    Order: slot_start is what all of them filter or sort on. appointment_id is
--    a second KEY column (not INCLUDE) because R22's keyset pagination and W02
--    order by (slot_start, appointment_id) to break ties between appointments
--    that share a slot; as a key column it gives that order for free.
--    INCLUDE (status, consult_type, patient_id, doctor_id): exactly the columns
--    the yearly reports read. They then scan about 1/3 of this index instead of
--    the whole 22 MB table.
--    Why B-tree and not BRIN: slot_start follows the physical row order almost
--    perfectly (correlation 0.9997), so a BRIN index would also find the June
--    pages, but BRIN cannot return rows in order (R21, R22, W02) and cannot do
--    Index Only Scans (the yearly reports). It is noted as an option for the
--    20x data in Phase 5.
-- ---------------------------------------------------------------------
CREATE INDEX ix_appt_slot_cover
    ON appointments (slot_start, appointment_id)
    INCLUDE (status, consult_type, patient_id, doctor_id);

-- ---------------------------------------------------------------------
-- 4. Open appointments only (partial index)
--    Serves: W04 (nightly job: BOOKED / CHECKED_IN appointments whose slot has
--    ended become NO_SHOW).
--    Partial: only 1,823 of 150,000 rows (1.2%) are BOOKED or CHECKED_IN, and
--    they leave the index as soon as they are completed, cancelled or marked
--    NO_SHOW, so the index stays small however large the table grows. The WHERE
--    clause is exactly W04's status condition, so the planner can use it.
--    Key slot_end: W04 filters on slot_end < '2026-07-02 00:00+05:30', so the
--    scan reads only the 329 rows it updates.
-- ---------------------------------------------------------------------
CREATE INDEX ix_appt_open_slot_end
    ON appointments (slot_end)
    WHERE status IN ('BOOKED', 'CHECKED_IN');

-- ---------------------------------------------------------------------
-- 5. Follow-up dates (partial index)
--    Serves: R11 (follow-ups due 1-7 July 2026).
--    Partial: follow_up_date is NULL in 68,184 of 97,234 prescriptions (70%),
--    and a NULL can never match a date range, so those rows are left out.
-- ---------------------------------------------------------------------
CREATE INDEX ix_presc_followup
    ON prescriptions (follow_up_date)
    WHERE follow_up_date IS NOT NULL;

-- ---------------------------------------------------------------------
-- 6. Allergy lists (GIN)
--    Serves: R10 (allergies @> ARRAY['Penicillin']).
--    GIN because allergies is an array: a GIN index stores one entry per
--    element, which is what the containment operator @> needs. A B-tree on an
--    array can only compare whole arrays.
-- ---------------------------------------------------------------------
CREATE INDEX ix_patients_allergies
    ON patients USING gin (allergies);

-- ---------------------------------------------------------------------
-- 7. Schedules by clinic
--    Serves: R13 (clinics with no schedule: NOT EXISTS probe by clinic_id),
--    and the "has a schedule at a clinic in city X" checks in R01, R18, R19.
--    The primary key (doctor_id, weekday, start_time) only helps when doctor_id
--    is known; these queries start from the clinic side. It is also the
--    foreign-key index that a DELETE on clinics needs for its RESTRICT check.
-- ---------------------------------------------------------------------
CREATE INDEX ix_sched_clinic
    ON doctor_schedules (clinic_id);

-- ---------------------------------------------------------------------
-- 8. Summary table for R14 (doctor ranking)
--    R14 must read every review ever written and join each one to its
--    appointment just to learn the doctor_id; no index avoids that. A ranking
--    does not need to be live to the second, so the per-doctor totals are kept
--    in a materialized view and R14 reads 3,000 rows instead of joining
--    30,339 reviews to 150,000 appointments.
--    avg_rating_exact keeps avg() unrounded and recommends keeps the raw count,
--    so the optimized R14 applies exactly the same round(...) expressions as
--    the original and returns identical values.
--    Refresh: nightly, REFRESH MATERIALIZED VIEW CONCURRENTLY (readers are not
--    blocked; needs the unique index below). A new review appears in the
--    ranking the next morning.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW doctor_rating_summary AS
SELECT a.doctor_id,
       count(*)                             AS reviews,
       avg(r.rating)                        AS avg_rating_exact,
       count(*) FILTER (WHERE r.recommends) AS recommends
FROM doctor_reviews r
JOIN appointments a ON a.appointment_id = r.appointment_id
GROUP BY a.doctor_id;

CREATE UNIQUE INDEX ux_rating_summary_doctor
    ON doctor_rating_summary (doctor_id);

-- ---------------------------------------------------------------------
-- 9. Summary table for R15 (pharmacy partners' monthly report)
--    R15 is a report about a closed calendar month. Its cost is the join of
--    prescription items -> prescriptions -> appointments -> primary
--    specialization, which the default cost model always runs as hash joins
--    over the full items and appointments tables. Keeping monthly counts per
--    (month, specialization, medicine) turns it into a lookup of 225 rows.
--    The month is computed in IST explicitly (AT TIME ZONE 'Asia/Kolkata'),
--    so the summary does not depend on the time zone of whoever refreshes it;
--    it matches R15's date range because the application runs with
--    timezone = Asia/Kolkata (docs/01_problem_understanding.md, assumption 1).
--    Refresh: nightly with REFRESH MATERIALIZED VIEW CONCURRENTLY; a closed
--    month (like June 2026 for a report run in July) never changes again.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW monthly_medicine_by_specialization AS
SELECT (date_trunc('month', p.issued_at AT TIME ZONE 'Asia/Kolkata'))::date AS month,
       s.spec_name,
       i.medicine_name,
       count(*) AS times_prescribed
FROM prescription_items i
JOIN prescriptions p           ON p.prescription_id = i.prescription_id
JOIN appointments a            ON a.appointment_id = p.appointment_id
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
JOIN specializations s         ON s.spec_id = ds.spec_id
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX ux_monthly_medicine
    ON monthly_medicine_by_specialization (month, spec_name, medicine_name);

-- ---------------------------------------------------------------------
-- 10. The purpose of each object, stored in the catalog
--    The same reasoning as the comments above, in one line each, so that \di+
--    and \dm+ in psql show why every object exists.
-- ---------------------------------------------------------------------
COMMENT ON INDEX ix_appt_doctor_slot IS
    'R03, R05, R19, W05: one doctor''s appointments in time order. INCLUDE (status, consult_ended_at) makes R19''s 960 lookups index-only.';
COMMENT ON INDEX ix_appt_patient IS
    'R04, R11: one patient''s appointments per doctor in time order; R11''s NOT EXISTS probe is two equalities and a range.';
COMMENT ON INDEX ix_appt_slot_cover IS
    'R08, R09, R12, R16, R17, R20, R21, R22, R25, W02: all appointments in (slot_start, appointment_id) order, covering the yearly reports.';
COMMENT ON INDEX ix_appt_open_slot_end IS
    'W04: partial, only the BOOKED / CHECKED_IN rows (1.2% of the seed data), keyed on slot_end.';
COMMENT ON INDEX ix_presc_followup IS
    'R11: partial, only the 30% of prescriptions that have a follow-up date.';
COMMENT ON INDEX ix_patients_allergies IS
    'R10: GIN on the allergies array, for allergies @> ARRAY[...].';
COMMENT ON INDEX ix_sched_clinic IS
    'R13 (NOT EXISTS by clinic) and the city checks of R01, R18, R19; also the foreign-key index for deletes on clinics.';
COMMENT ON MATERIALIZED VIEW doctor_rating_summary IS
    'R14: review count, exact average rating and recommendations per doctor. Refreshed nightly with REFRESH MATERIALIZED VIEW CONCURRENTLY.';
COMMENT ON INDEX ux_rating_summary_doctor IS
    'Unique key that REFRESH MATERIALIZED VIEW CONCURRENTLY needs.';
COMMENT ON MATERIALIZED VIEW monthly_medicine_by_specialization IS
    'R15: prescriptions per month (IST), primary specialization and medicine. Refreshed nightly with REFRESH MATERIALIZED VIEW CONCURRENTLY.';
COMMENT ON INDEX ux_monthly_medicine IS
    'Unique key that REFRESH MATERIALIZED VIEW CONCURRENTLY needs; R15 also uses it to find one month.';

-- ---------------------------------------------------------------------
-- 11. VACUUM + ANALYZE
--    ANALYZE gives the planner statistics for the new objects. VACUUM sets the
--    visibility map: an Index Only Scan can skip the table only for pages
--    marked all-visible, so without it the "covering" indexes above would
--    still visit the heap. Autovacuum keeps this up to date afterwards.
-- ---------------------------------------------------------------------
VACUUM (ANALYZE) appointments;
VACUUM (ANALYZE) prescriptions;
VACUUM (ANALYZE) patients;
VACUUM (ANALYZE) doctor_schedules;
VACUUM (ANALYZE) doctor_rating_summary;
VACUUM (ANALYZE) monthly_medicine_by_specialization;

-- Nightly maintenance for the two summary tables (run by the scheduler):
--   REFRESH MATERIALIZED VIEW CONCURRENTLY practo.doctor_rating_summary;
--   REFRESH MATERIALIZED VIEW CONCURRENTLY practo.monthly_medicine_by_specialization;
