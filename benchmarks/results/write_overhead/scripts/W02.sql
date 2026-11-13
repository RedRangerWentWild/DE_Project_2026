BEGIN;
UPDATE appointments SET status = 'CHECKED_IN', checked_in_at = slot_start - interval '5 minutes' WHERE appointment_id = (SELECT appointment_id FROM appointments                         WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC'                           AND slot_start >= '2026-07-01' AND slot_start < '2026-07-02'                         ORDER BY slot_start LIMIT 1);  
ROLLBACK;
