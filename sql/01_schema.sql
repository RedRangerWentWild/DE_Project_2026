-- =====================================================================
-- Practo Doctor Appointments Database - Phase 2 schema
-- Team T0015 (Bluetrace), Section E
--
-- Run on an empty database:   psql -d practo -f sql/01_schema.sql
--
-- Only constraints are created here (PK, FK, UNIQUE, NOT NULL, CHECK).
-- No tuning indexes: the Phase 3 baseline must reflect an untuned database.
-- Indexes PostgreSQL creates by itself for PRIMARY KEY / UNIQUE are listed
-- in docs/02_schema_design.md.
-- =====================================================================

DROP SCHEMA IF EXISTS practo CASCADE;   -- makes the script re-runnable
CREATE SCHEMA practo;
SET search_path TO practo;

-- ---------------------------------------------------------------------
-- 1. cities  (lookup, 10 rows)
-- ---------------------------------------------------------------------
CREATE TABLE cities (
    city_id   SMALLINT     PRIMARY KEY,
    city_name VARCHAR(50)  NOT NULL,
    state     VARCHAR(50)  NOT NULL,
    CONSTRAINT uq_cities_name_state UNIQUE (city_name, state)
);

-- ---------------------------------------------------------------------
-- 2. specializations  (lookup, 15 rows)
-- ---------------------------------------------------------------------
CREATE TABLE specializations (
    spec_id   SMALLINT     PRIMARY KEY,
    spec_name VARCHAR(50)  NOT NULL,
    CONSTRAINT uq_specializations_name UNIQUE (spec_name)
);

-- ---------------------------------------------------------------------
-- 3. doctors  (3,000 rows)
-- ---------------------------------------------------------------------
CREATE TABLE doctors (
    doctor_id        INTEGER       PRIMARY KEY,
    full_name        VARCHAR(100)  NOT NULL,
    registration_no  VARCHAR(11)   NOT NULL,
    gender           CHAR(1)       NOT NULL,
    experience_years SMALLINT      NOT NULL,
    consultation_fee NUMERIC(8,2)  NOT NULL,
    video_fee        NUMERIC(8,2),             -- NULL = doctor does not offer video consultations
    languages        TEXT[]        NOT NULL,
    is_verified      BOOLEAN       NOT NULL DEFAULT FALSE,
    joined_on        DATE          NOT NULL,
    CONSTRAINT uq_doctors_registration_no UNIQUE (registration_no),
    -- state medical council code + 6 digits, e.g. DLMC-010007
    CONSTRAINT ck_doctors_registration_no CHECK (registration_no ~ '^[A-Z]{2}MC-[0-9]{6}$'),
    CONSTRAINT ck_doctors_gender          CHECK (gender IN ('M', 'F', 'X')),
    CONSTRAINT ck_doctors_experience      CHECK (experience_years BETWEEN 0 AND 70),
    CONSTRAINT ck_doctors_consult_fee     CHECK (consultation_fee > 0),
    CONSTRAINT ck_doctors_video_fee       CHECK (video_fee IS NULL OR video_fee > 0),
    -- at least one language, and no NULL element inside the array
    CONSTRAINT ck_doctors_languages       CHECK (cardinality(languages) >= 1
                                                 AND array_position(languages, NULL) IS NULL)
);

-- ---------------------------------------------------------------------
-- 4. doctor_specializations  (M:N doctors <-> specializations, 3,700 rows)
-- ---------------------------------------------------------------------
CREATE TABLE doctor_specializations (
    doctor_id  INTEGER   NOT NULL,
    spec_id    SMALLINT  NOT NULL,
    is_primary BOOLEAN   NOT NULL DEFAULT FALSE,
    CONSTRAINT pk_doctor_specializations PRIMARY KEY (doctor_id, spec_id),
    CONSTRAINT fk_ds_doctor FOREIGN KEY (doctor_id) REFERENCES doctors (doctor_id)       ON DELETE CASCADE,
    CONSTRAINT fk_ds_spec   FOREIGN KEY (spec_id)   REFERENCES specializations (spec_id) ON DELETE RESTRICT
);

-- "At most one primary specialization per doctor."
-- PostgreSQL has no partial UNIQUE *constraint* syntax, so this uniqueness rule
-- can only be declared as a partial unique index. It is a constraint, not tuning.
CREATE UNIQUE INDEX uq_ds_one_primary_per_doctor
    ON doctor_specializations (doctor_id)
    WHERE is_primary;

-- ---------------------------------------------------------------------
-- 5. clinics  (1,500 rows)
-- ---------------------------------------------------------------------
CREATE TABLE clinics (
    clinic_id   INTEGER       PRIMARY KEY,
    clinic_name VARCHAR(100)  NOT NULL,
    city_id     SMALLINT      NOT NULL,
    locality    VARCHAR(60)   NOT NULL,
    latitude    NUMERIC(9,6)  NOT NULL,
    longitude   NUMERIC(9,6)  NOT NULL,
    phone       VARCHAR(15)   NOT NULL,
    CONSTRAINT uq_clinics_phone UNIQUE (phone),
    CONSTRAINT fk_clinics_city  FOREIGN KEY (city_id) REFERENCES cities (city_id) ON DELETE RESTRICT,
    CONSTRAINT ck_clinics_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_clinics_longitude CHECK (longitude BETWEEN -180 AND 180),
    -- Indian landline: +91-<2 digit STD>-<7 digits>
    CONSTRAINT ck_clinics_phone     CHECK (phone ~ '^\+91-[0-9]{2}-[0-9]{7}$')
);

-- ---------------------------------------------------------------------
-- 6. doctor_schedules  (weekly timetable, 30,499 rows)
--    clinic_id NULL  = a video-consultation block
-- ---------------------------------------------------------------------
CREATE TABLE doctor_schedules (
    doctor_id    INTEGER   NOT NULL,
    weekday      SMALLINT  NOT NULL,   -- PostgreSQL DOW numbering: 0 = Sunday ... 6 = Saturday
    start_time   TIME      NOT NULL,
    end_time     TIME      NOT NULL,
    clinic_id    INTEGER,
    slot_minutes SMALLINT  NOT NULL,
    -- a doctor cannot start two blocks at the same moment, whatever the place
    CONSTRAINT pk_doctor_schedules PRIMARY KEY (doctor_id, weekday, start_time),
    CONSTRAINT fk_sched_doctor FOREIGN KEY (doctor_id) REFERENCES doctors (doctor_id) ON DELETE CASCADE,
    -- RESTRICT, not SET NULL: SET NULL would silently turn a clinic block into a video block
    CONSTRAINT fk_sched_clinic FOREIGN KEY (clinic_id) REFERENCES clinics (clinic_id) ON DELETE RESTRICT,
    CONSTRAINT ck_sched_weekday      CHECK (weekday BETWEEN 0 AND 6),
    CONSTRAINT ck_sched_time_order   CHECK (end_time > start_time),
    CONSTRAINT ck_sched_slot_minutes CHECK (slot_minutes IN (10, 15, 20))
);

-- ---------------------------------------------------------------------
-- 7. patients  (40,000 rows)
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id  INTEGER       PRIMARY KEY,
    full_name   VARCHAR(100)  NOT NULL,
    phone       VARCHAR(10)   NOT NULL,   -- sign-in identifier
    email       VARCHAR(254),             -- optional
    dob         DATE          NOT NULL,
    gender      CHAR(1)       NOT NULL,
    blood_group VARCHAR(3),               -- NULL = not known / never tested
    allergies   TEXT[],                   -- NULL = no known allergies
    city_id     SMALLINT      NOT NULL,
    created_at  TIMESTAMPTZ   NOT NULL,
    CONSTRAINT uq_patients_phone UNIQUE (phone),
    CONSTRAINT uq_patients_email UNIQUE (email),   -- UNIQUE ignores NULLs, so many patients may have no email
    CONSTRAINT fk_patients_city  FOREIGN KEY (city_id) REFERENCES cities (city_id) ON DELETE RESTRICT,
    -- 10-digit Indian mobile number starting 6-9
    CONSTRAINT ck_patients_phone       CHECK (phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT ck_patients_email       CHECK (email IS NULL OR email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$'),
    CONSTRAINT ck_patients_gender      CHECK (gender IN ('M', 'F', 'X')),
    CONSTRAINT ck_patients_blood_group CHECK (blood_group IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')),
    CONSTRAINT ck_patients_dob         CHECK (dob >= DATE '1900-01-01'),
    -- one representation only for "no allergies": NULL, never an empty array
    CONSTRAINT ck_patients_allergies   CHECK (allergies IS NULL
                                              OR (cardinality(allergies) >= 1
                                                  AND array_position(allergies, NULL) IS NULL))
);

-- ---------------------------------------------------------------------
-- 8. appointments  (150,000 rows; the fact table)
-- ---------------------------------------------------------------------
CREATE TABLE appointments (
    appointment_id     INTEGER       PRIMARY KEY,
    patient_id         INTEGER       NOT NULL,
    doctor_id          INTEGER       NOT NULL,
    clinic_id          INTEGER,                 -- NULL for video consultations
    consult_type       VARCHAR(10)   NOT NULL,
    booked_at          TIMESTAMPTZ   NOT NULL,
    slot_start         TIMESTAMPTZ   NOT NULL,
    slot_end           TIMESTAMPTZ   NOT NULL,
    reason             VARCHAR(200)  NOT NULL,
    status             VARCHAR(12)   NOT NULL DEFAULT 'BOOKED',
    checked_in_at      TIMESTAMPTZ,             -- only clinic visits are checked in
    consult_started_at TIMESTAMPTZ,
    consult_ended_at   TIMESTAMPTZ,
    fee                NUMERIC(8,2)  NOT NULL,  -- price snapshot at booking time
    payment_status     VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    -- RESTRICT everywhere: an appointment is a medical and financial record and
    -- must never disappear because a patient, doctor or clinic row was deleted.
    CONSTRAINT fk_appt_patient FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE RESTRICT,
    CONSTRAINT fk_appt_doctor  FOREIGN KEY (doctor_id)  REFERENCES doctors (doctor_id)   ON DELETE RESTRICT,
    CONSTRAINT fk_appt_clinic  FOREIGN KEY (clinic_id)  REFERENCES clinics (clinic_id)   ON DELETE RESTRICT,
    CONSTRAINT ck_appt_consult_type   CHECK (consult_type IN ('IN_CLINIC', 'VIDEO')),
    CONSTRAINT ck_appt_status         CHECK (status IN ('BOOKED', 'CHECKED_IN', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT ck_appt_payment_status CHECK (payment_status IN ('PENDING', 'PAID', 'REFUNDED')),
    CONSTRAINT ck_appt_fee            CHECK (fee >= 0),
    CONSTRAINT ck_appt_slot_order     CHECK (slot_end > slot_start),
    CONSTRAINT ck_appt_booked_before_slot CHECK (booked_at <= slot_start),
    -- in-clinic <=> has a clinic
    CONSTRAINT ck_appt_clinic_iff_in_clinic CHECK ((consult_type = 'IN_CLINIC') = (clinic_id IS NOT NULL)),
    -- only clinic visits are checked in
    CONSTRAINT ck_appt_checkin_only_in_clinic CHECK (checked_in_at IS NULL OR consult_type = 'IN_CLINIC'),
    -- status CHECKED_IN needs the check-in time
    CONSTRAINT ck_appt_checked_in_has_time CHECK (status <> 'CHECKED_IN' OR checked_in_at IS NOT NULL),
    -- a consultation cannot end unless it started, and it ends after it starts
    CONSTRAINT ck_appt_consult_order  CHECK (consult_ended_at IS NULL
                                             OR (consult_started_at IS NOT NULL AND consult_ended_at > consult_started_at)),
    -- COMPLETED <=> the consultation has an end time
    CONSTRAINT ck_appt_completed_iff_ended CHECK ((status = 'COMPLETED') = (consult_ended_at IS NOT NULL)),
    -- refunds only for cancellations
    CONSTRAINT ck_appt_refund_only_cancelled CHECK (payment_status <> 'REFUNDED' OR status = 'CANCELLED')
);

-- ---------------------------------------------------------------------
-- 9. prescriptions  (1:1 with a completed appointment, 97,234 rows)
-- ---------------------------------------------------------------------
CREATE TABLE prescriptions (
    prescription_id INTEGER       PRIMARY KEY,
    appointment_id  INTEGER       NOT NULL,
    diagnosis       VARCHAR(200)  NOT NULL,
    notes           TEXT,
    follow_up_date  DATE,                     -- NULL = no follow-up needed
    issued_at       TIMESTAMPTZ   NOT NULL,
    CONSTRAINT uq_prescriptions_appointment UNIQUE (appointment_id),   -- one prescription per appointment
    CONSTRAINT fk_presc_appointment FOREIGN KEY (appointment_id) REFERENCES appointments (appointment_id) ON DELETE RESTRICT,
    -- a follow-up is always after the day the prescription was written (IST)
    CONSTRAINT ck_presc_follow_up CHECK (follow_up_date IS NULL
                                         OR follow_up_date > (issued_at AT TIME ZONE 'Asia/Kolkata')::date)
);

-- ---------------------------------------------------------------------
-- 10. prescription_items  (weak entity of prescriptions, 243,085 rows)
-- ---------------------------------------------------------------------
CREATE TABLE prescription_items (
    prescription_id INTEGER       NOT NULL,
    line_no         SMALLINT      NOT NULL,
    medicine_name   VARCHAR(100)  NOT NULL,
    dosage          VARCHAR(5)    NOT NULL,   -- morning-afternoon-night, e.g. 1-0-1
    duration_days   SMALLINT      NOT NULL,
    instructions    VARCHAR(100),
    CONSTRAINT pk_prescription_items PRIMARY KEY (prescription_id, line_no),
    -- CASCADE: a line cannot exist without its prescription
    CONSTRAINT fk_items_prescription FOREIGN KEY (prescription_id) REFERENCES prescriptions (prescription_id) ON DELETE CASCADE,
    CONSTRAINT ck_items_line_no  CHECK (line_no >= 1),
    CONSTRAINT ck_items_dosage   CHECK (dosage ~ '^[0-9]-[0-9]-[0-9]$' AND dosage <> '0-0-0'),
    CONSTRAINT ck_items_duration CHECK (duration_days BETWEEN 1 AND 365)
);

-- ---------------------------------------------------------------------
-- 11. doctor_reviews  (at most one review per appointment, 30,339 rows)
-- ---------------------------------------------------------------------
CREATE TABLE doctor_reviews (
    review_id        INTEGER      PRIMARY KEY,
    appointment_id   INTEGER      NOT NULL,
    rating           SMALLINT     NOT NULL,
    recommends       BOOLEAN      NOT NULL,
    wait_time_bucket VARCHAR(10)  NOT NULL,
    review_text      TEXT,
    created_at       TIMESTAMPTZ  NOT NULL,
    CONSTRAINT uq_reviews_appointment UNIQUE (appointment_id),
    -- CASCADE: a review is an opinion about one appointment and has no meaning without it
    CONSTRAINT fk_reviews_appointment FOREIGN KEY (appointment_id) REFERENCES appointments (appointment_id) ON DELETE CASCADE,
    CONSTRAINT ck_reviews_rating      CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT ck_reviews_wait_bucket CHECK (wait_time_bucket IN ('<15 min', '15-30 min', '30-60 min', '>1 hr'))
);
