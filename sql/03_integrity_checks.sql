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

-- IC7: no two active (not cancelled) appointments share a doctor and a slot,
-- and no patient holds two active appointments that start at the same time.
-- Seed data: 559 pairs and 23 patients (data problem 1). This is why there
-- is no UNIQUE (doctor_id, slot_start); R24 is the report that lists them.
SELECT 'IC7' AS ic,
       (SELECT count(*) FROM appointments a
        JOIN appointments b ON b.doctor_id = a.doctor_id AND b.slot_start = a.slot_start
                           AND b.appointment_id > a.appointment_id
        WHERE a.status <> 'CANCELLED' AND b.status <> 'CANCELLED') AS double_booked_pairs,
       (SELECT count(DISTINCT a.patient_id) FROM appointments a
        JOIN appointments b ON b.patient_id = a.patient_id AND b.slot_start = a.slot_start
                           AND b.appointment_id > a.appointment_id
        WHERE a.status <> 'CANCELLED' AND b.status <> 'CANCELLED') AS double_booked_patients;

-- IC8: check-in happens after booking and before the consultation starts, and
-- no consultation starts before its slot. Seed data: 16,183 / 5 / 0
-- (data problem 3), which is why checked_in_at has no ordering CHECK.
SELECT 'IC8' AS ic,
       count(*) FILTER (WHERE checked_in_at > consult_started_at) AS checkin_after_consult_start,
       count(*) FILTER (WHERE checked_in_at < booked_at)          AS checkin_before_booking,
       count(*) FILTER (WHERE consult_started_at < slot_start)    AS started_before_slot
FROM appointments;

-- IC9: a doctor has a video_fee exactly when they have a video schedule
-- block, and every doctor has a primary specialization. Seed data: 0 / 0.
SELECT 'IC9' AS ic,
       (SELECT count(*) FROM doctors d
        WHERE (d.video_fee IS NOT NULL)
              <> EXISTS (SELECT 1 FROM doctor_schedules s
                         WHERE s.doctor_id = d.doctor_id AND s.clinic_id IS NULL)) AS video_fee_vs_video_schedule,
       (SELECT count(*) FROM doctors d
        WHERE NOT EXISTS (SELECT 1 FROM doctor_specializations ds
                          WHERE ds.doctor_id = d.doctor_id AND ds.is_primary)) AS doctors_without_primary_spec;

-- IC10: clinics with no schedule, counted correctly (NOT EXISTS) and the way
-- R13 counts them (NOT IN over a column that contains NULLs). Seed data:
-- 292 vs 0 (data problem 5). The two must agree once R13 is fixed.
SELECT 'IC10' AS ic,
       (SELECT count(*) FROM clinics c
        WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules s WHERE s.clinic_id = c.clinic_id)) AS not_exists_answer,
       (SELECT count(*) FROM clinics c
        WHERE c.clinic_id NOT IN (SELECT s.clinic_id FROM doctor_schedules s)) AS r13_not_in_answer;

-- IC11: a doctor's schedule blocks on one weekday do not overlap (two blocks
-- cannot start at the same time, the primary key forbids it, so an overlap
-- means one starts inside the other), and nothing is booked before the
-- patient signed up or before the doctor joined (IST date). Seed data:
-- 0 / 1,072 / 0 (data problem 4).
SELECT 'IC11' AS ic,
       (SELECT count(*) FROM doctor_schedules s
        JOIN doctor_schedules t ON t.doctor_id = s.doctor_id AND t.weekday = s.weekday
                               AND t.start_time > s.start_time AND t.start_time < s.end_time) AS overlapping_blocks,
       (SELECT count(*) FROM appointments a
        JOIN patients p ON p.patient_id = a.patient_id
        WHERE a.booked_at < p.created_at) AS booked_before_signup,
       (SELECT count(*) FROM appointments a
        JOIN doctors d ON d.doctor_id = a.doctor_id
        WHERE (a.booked_at AT TIME ZONE 'Asia/Kolkata')::date < d.joined_on) AS booked_before_doctor_joined;
