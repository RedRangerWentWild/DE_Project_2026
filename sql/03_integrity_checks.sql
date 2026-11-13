-- =====================================================================
-- Practo Doctor Appointments Database - Phase 2 integrity checks
-- Team T0015 (Bluetrace), Section E
--
-- Rules that a CHECK constraint cannot express, because each one compares
-- rows of different tables, or different rows of the same table. The results
-- and what they mean are in docs/02_schema_design.md, sections 8 and 9.
--
-- Run after sql/02_load_data.sql:
--     psql -d practo -f sql/03_integrity_checks.sql
--
-- Every query is read-only and returns one row: the check id and the number
-- of rows that break the rule, under the column names used in the doc. The
-- value each check returns on the seed data is noted above it. Weekdays and
-- dates are taken in IST explicitly (AT TIME ZONE 'Asia/Kolkata'), so the
-- results do not depend on the session time zone.
-- =====================================================================
SET search_path TO practo;

-- IC1: every appointment falls inside a schedule block of that doctor on that
-- weekday, at the same place (clinic, or NULL for video) and with the same
-- slot length. Seed data: 0.
SELECT 'IC1' AS ic, count(*) AS outside_schedule
FROM appointments a
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules s
                  WHERE s.doctor_id = a.doctor_id
                    AND s.weekday = EXTRACT(DOW FROM a.slot_start AT TIME ZONE 'Asia/Kolkata')
                    AND (a.slot_start AT TIME ZONE 'Asia/Kolkata')::time >= s.start_time
                    AND (a.slot_end   AT TIME ZONE 'Asia/Kolkata')::time <= s.end_time
                    AND s.clinic_id IS NOT DISTINCT FROM a.clinic_id
                    AND a.slot_end - a.slot_start = s.slot_minutes * interval '1 minute');

-- IC2: an in-clinic appointment is at a clinic where the doctor has a
-- schedule. Seed data: 0.
SELECT 'IC2' AS ic, count(*) AS wrong_clinic
FROM appointments a
WHERE a.clinic_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM doctor_schedules s
                  WHERE s.doctor_id = a.doctor_id AND s.clinic_id = a.clinic_id);

-- IC3: no patient allergic to penicillin is prescribed amoxicillin (the
-- question R10 asks). Seed data: 726 prescription lines, 545 patients
-- (data problem 2).
SELECT 'IC3' AS ic, count(*) AS conflict_lines, count(DISTINCT pt.patient_id) AS patients
FROM patients pt
JOIN appointments a       ON a.patient_id = pt.patient_id
JOIN prescriptions p      ON p.appointment_id = a.appointment_id
JOIN prescription_items i ON i.prescription_id = p.prescription_id
WHERE pt.allergies @> ARRAY['Penicillin'] AND i.medicine_name ILIKE '%amoxicillin%';

-- IC4: appointments.fee is the doctor's fee for that consult type
-- (consultation_fee in the clinic, video_fee for a video call), i.e. a price
-- snapshot that has not drifted. Seed data: 0.
SELECT 'IC4' AS ic, count(*) AS fee_mismatch
FROM appointments a
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.fee IS DISTINCT FROM CASE a.consult_type WHEN 'IN_CLINIC' THEN d.consultation_fee
                                                 ELSE d.video_fee END;

-- IC5: a review's wait_time_bucket agrees with the actual wait,
-- consult_started_at - slot_start: under 15 minutes, under 30, under 60,
-- otherwise '>1 hr' (a wait of exactly 60 minutes is '>1 hr'). Seed data: 0.
SELECT 'IC5' AS ic, count(*) AS bucket_mismatch
FROM doctor_reviews r
JOIN appointments a ON a.appointment_id = r.appointment_id
CROSS JOIN LATERAL (SELECT a.consult_started_at - a.slot_start AS wait) w
WHERE r.wait_time_bucket IS DISTINCT FROM
      CASE WHEN w.wait < interval '15 minutes' THEN '<15 min'
           WHEN w.wait < interval '30 minutes' THEN '15-30 min'
           WHEN w.wait < interval '60 minutes' THEN '30-60 min'
           ELSE '>1 hr' END;

-- IC6: prescriptions and reviews exist only for COMPLETED appointments, and
-- every prescription has at least one medicine. Seed data: 0 / 0 / 0.
SELECT 'IC6' AS ic,
       (SELECT count(*) FROM prescriptions p
        JOIN appointments a ON a.appointment_id = p.appointment_id
        WHERE a.status <> 'COMPLETED') AS presc_not_completed,
       (SELECT count(*) FROM doctor_reviews r
        JOIN appointments a ON a.appointment_id = r.appointment_id
        WHERE a.status <> 'COMPLETED') AS review_not_completed,
       (SELECT count(*) FROM prescriptions p
        WHERE NOT EXISTS (SELECT 1 FROM prescription_items i
                          WHERE i.prescription_id = p.prescription_id)) AS presc_without_items;
