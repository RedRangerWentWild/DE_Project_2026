BEGIN;
UPDATE prescriptions SET notes = 'Review blood sugar after 2 weeks', follow_up_date = '2026-07-15' WHERE appointment_id = 18872;  
ROLLBACK;
