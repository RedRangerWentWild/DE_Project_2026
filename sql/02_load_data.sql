-- =====================================================================
-- Practo Doctor Appointments Database - Phase 2 data load
-- Team T0015 (Bluetrace), Section E
--
-- Run from the repository root (so the relative CSV paths resolve), after
-- sql/01_schema.sql, with seed_data.zip unzipped into seed_data/:
--
--     psql -d practo -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
--
-- For the large dataset change the folder name only (seed_data -> large_data).
-- Order = parents before children, so every foreign key is satisfied.
-- =====================================================================
SET search_path TO practo;

BEGIN;   -- all 11 files load, or none do

-- level 0: no foreign keys
\copy cities                 FROM 'seed_data/cities.csv'                 WITH (FORMAT csv, HEADER true)
\copy specializations        FROM 'seed_data/specializations.csv'        WITH (FORMAT csv, HEADER true)
\copy doctors                FROM 'seed_data/doctors.csv'                WITH (FORMAT csv, HEADER true)

-- level 1: depend on cities / doctors / specializations
\copy doctor_specializations FROM 'seed_data/doctor_specializations.csv' WITH (FORMAT csv, HEADER true)
\copy clinics                FROM 'seed_data/clinics.csv'                WITH (FORMAT csv, HEADER true)
\copy patients               FROM 'seed_data/patients.csv'               WITH (FORMAT csv, HEADER true)

-- level 2: depend on doctors + clinics
\copy doctor_schedules       FROM 'seed_data/doctor_schedules.csv'       WITH (FORMAT csv, HEADER true)

-- level 3: depend on patients + doctors + clinics
\copy appointments           FROM 'seed_data/appointments.csv'           WITH (FORMAT csv, HEADER true)

-- level 4: depend on appointments
\copy prescriptions          FROM 'seed_data/prescriptions.csv'          WITH (FORMAT csv, HEADER true)
\copy doctor_reviews         FROM 'seed_data/doctor_reviews.csv'         WITH (FORMAT csv, HEADER true)

-- level 5: depend on prescriptions
\copy prescription_items     FROM 'seed_data/prescription_items.csv'     WITH (FORMAT csv, HEADER true)

COMMIT;

ANALYZE;

-- Row counts: must match the table in README.md (Phase 2)
SELECT 'cities' AS table_name, count(*) AS rows, 10 AS expected FROM cities
UNION ALL SELECT 'specializations',        count(*), 15     FROM specializations
UNION ALL SELECT 'doctors',                count(*), 3000   FROM doctors
UNION ALL SELECT 'doctor_specializations', count(*), 3700   FROM doctor_specializations
UNION ALL SELECT 'clinics',                count(*), 1500   FROM clinics
UNION ALL SELECT 'doctor_schedules',       count(*), 30499  FROM doctor_schedules
UNION ALL SELECT 'patients',               count(*), 40000  FROM patients
UNION ALL SELECT 'appointments',           count(*), 150000 FROM appointments
UNION ALL SELECT 'prescriptions',          count(*), 97234  FROM prescriptions
UNION ALL SELECT 'prescription_items',     count(*), 243085 FROM prescription_items
UNION ALL SELECT 'doctor_reviews',         count(*), 30339  FROM doctor_reviews;
