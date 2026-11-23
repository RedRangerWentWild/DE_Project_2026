-- =====================================================================
-- Practo Doctor Appointments Database - Phase 5 Partitioning
-- Contributed by Abhishek Panigrahi (Abhishek-047), Team T0015
--
-- Why Partitioning?
-- At 150,000 rows (seed), the appointments table is ~22 MB.
-- At 20x (3,000,000 rows), it grows to ~450 MB.
-- At 100x (15,000,000 rows), it exceeds 2.2 GB.
--
-- Most hot queries (R03, R05, R08, R09, R12, R16, R17, R20, R21, R22, W02, W04)
-- filter or sort by slot_start. Range partitioning by slot_start allows
-- PostgreSQL's query engine to perform PARTITION PRUNING: scanning only
-- the partition containing the target date range and skipping all others.
--
-- Rule in PostgreSQL:
-- Any PRIMARY KEY or UNIQUE constraint on a partitioned table must include
-- the partition key column (slot_start).
-- =====================================================================

SET search_path TO practo;

-- ---------------------------------------------------------------------
-- 1. Create the partitioned master table
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS appointments_partitioned (
    appointment_id     INTEGER       NOT NULL,
    patient_id         INTEGER       NOT NULL,
    doctor_id          INTEGER       NOT NULL,
    clinic_id          INTEGER,
    consult_type       VARCHAR(10)   NOT NULL,
    booked_at          TIMESTAMPTZ   NOT NULL,
    slot_start         TIMESTAMPTZ   NOT NULL,
    slot_end           TIMESTAMPTZ   NOT NULL,
    reason             VARCHAR(200)  NOT NULL,
    status             VARCHAR(12)   NOT NULL DEFAULT 'BOOKED',
    checked_in_at      TIMESTAMPTZ,
    consult_started_at TIMESTAMPTZ,
    consult_ended_at   TIMESTAMPTZ,
    fee                NUMERIC(8,2)  NOT NULL,
    payment_status     VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    -- Primary key must include the partition key (slot_start)
    CONSTRAINT pk_appointments_part PRIMARY KEY (appointment_id, slot_start),
    CONSTRAINT fk_appt_part_patient FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE RESTRICT,
    CONSTRAINT fk_appt_part_doctor  FOREIGN KEY (doctor_id)  REFERENCES doctors (doctor_id)   ON DELETE RESTRICT,
    CONSTRAINT fk_appt_part_clinic  FOREIGN KEY (clinic_id)  REFERENCES clinics (clinic_id)   ON DELETE RESTRICT,
    CONSTRAINT ck_appt_part_consult_type   CHECK (consult_type IN ('IN_CLINIC', 'VIDEO')),
    CONSTRAINT ck_appt_part_status         CHECK (status IN ('BOOKED', 'CHECKED_IN', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT ck_appt_part_payment_status CHECK (payment_status IN ('PENDING', 'PAID', 'REFUNDED')),
    CONSTRAINT ck_appt_part_fee            CHECK (fee >= 0),
    CONSTRAINT ck_appt_part_slot_order     CHECK (slot_end > slot_start),
    CONSTRAINT ck_appt_part_booked_before_slot CHECK (booked_at <= slot_start)
) PARTITION BY RANGE (slot_start);

-- ---------------------------------------------------------------------
-- 2. Declarative Partitions, one per quarter (2025 and 2026)
-- ---------------------------------------------------------------------
-- The seed data runs from 1 Jan 2025 to 30 Jun 2026. Without the 2025
-- quarters, two thirds of the appointments would land in the DEFAULT
-- partition, which a date range can never prune.
CREATE TABLE IF NOT EXISTS appointments_2025_q1 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-04-01 00:00:00+05:30');

CREATE TABLE IF NOT EXISTS appointments_2025_q2 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2025-04-01 00:00:00+05:30') TO ('2025-07-01 00:00:00+05:30');

CREATE TABLE IF NOT EXISTS appointments_2025_q3 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2025-07-01 00:00:00+05:30') TO ('2025-10-01 00:00:00+05:30');

CREATE TABLE IF NOT EXISTS appointments_2025_q4 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2025-10-01 00:00:00+05:30') TO ('2026-01-01 00:00:00+05:30');

-- Q1 2026: Jan 1 to Apr 1
CREATE TABLE IF NOT EXISTS appointments_2026_q1 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2026-01-01 00:00:00+05:30') TO ('2026-04-01 00:00:00+05:30');

-- Q2 2026: Apr 1 to Jul 1 (Holds bulk of seed active data)
CREATE TABLE IF NOT EXISTS appointments_2026_q2 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2026-04-01 00:00:00+05:30') TO ('2026-07-01 00:00:00+05:30');

-- Q3 2026: Jul 1 to Oct 1
CREATE TABLE IF NOT EXISTS appointments_2026_q3 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2026-07-01 00:00:00+05:30') TO ('2026-10-01 00:00:00+05:30');

-- Q4 2026: Oct 1 to Jan 1, 2027
CREATE TABLE IF NOT EXISTS appointments_2026_q4 PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2026-10-01 00:00:00+05:30') TO ('2027-01-01 00:00:00+05:30');

-- Default partition for data before 2025 or after 2026
CREATE TABLE IF NOT EXISTS appointments_default PARTITION OF appointments_partitioned DEFAULT;

-- ---------------------------------------------------------------------
-- 3. Local Indexes on the Partitioned Table
-- Indexes created on the partitioned parent automatically propagate to all partitions.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_appt_part_doctor_slot
    ON appointments_partitioned (doctor_id, slot_start)
    INCLUDE (status, consult_ended_at);

CREATE INDEX IF NOT EXISTS ix_appt_part_patient
    ON appointments_partitioned (patient_id, doctor_id, slot_start)
    INCLUDE (status);

CREATE INDEX IF NOT EXISTS ix_appt_part_slot_cover
    ON appointments_partitioned (slot_start, appointment_id)
    INCLUDE (status, consult_type, patient_id, doctor_id);

-- ---------------------------------------------------------------------
-- 4. Demonstration of Partition Pruning:
-- Querying a specific month (e.g., June 2026) only accesses appointments_2026_q2.
-- EXPLAIN SELECT * FROM appointments_partitioned
-- WHERE slot_start >= '2026-06-01 00:00:00+05:30' AND slot_start < '2026-07-01 00:00:00+05:30';
-- ---------------------------------------------------------------------
