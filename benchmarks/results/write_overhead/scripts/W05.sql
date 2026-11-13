BEGIN;
UPDATE appointments SET status = 'CANCELLED', payment_status = 'REFUNDED' WHERE doctor_id = 504 AND status = 'BOOKED'   AND slot_start >= '2026-07-03' AND slot_start < '2026-07-04';  
ROLLBACK;
