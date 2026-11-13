BEGIN;
UPDATE appointments SET status = 'NO_SHOW' WHERE status IN ('BOOKED', 'CHECKED_IN')   AND slot_end < '2026-07-02 00:00:00+05:30'   AND consult_ended_at IS NULL;  
ROLLBACK;
