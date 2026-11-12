# Phase 1 - Problem understanding

**Team T0015 (Bluetrace), Section E**

Practo's database was built in a hurry and has no documented schema. Seven teams report problems. Below is what each one actually needs, who is hurt, and whether it is a screen someone is waiting on (real-time) or a report (analytics).

| # | What the business needs (in our words) | Stakeholders affected | Class | Queries |
|---|----------------------------------------|-----------------------|-------|---------|
| P1 | A patient must find a doctor by specialization, city and language, open the profile, and see free slots without waiting. Free slots are not stored; they are generated from the weekly schedule and then compared with existing appointments, so this gets slower as appointments grow. | Patient; doctor (loses bookings when search is slow) | Customer-facing / real-time | R01, R02, R03, R18 |
| P2 | A signed-in patient must see their own upcoming appointments and prescriptions, sign in by mobile number, and book a slot immediately. Each of these touches one patient or one appointment, so it should cost the same however large the table is. | Patient; support (gets the complaints) | Customer-facing / real-time | R04, R06, R07, W01 |
| P3 | The receptionist needs one doctor's queue for today and must be able to mark a patient as arrived while the patient is standing at the desk. | Clinic reception; doctor; patient | Customer-facing / real-time | R05, W02 |
| P4 | Dangerous situations must be found before they hurt someone: a medicine prescribed to an allergic patient, a follow-up the patient never booked, and a patient visiting many doctors of the same specialization. Doctors must also be able to add a follow-up date quickly. | Patient-safety team; care team; doctor; patient | Mixed: R11 and W03 are interactive tools, R10 and R25 are reports | R10, R11, R25, W03 |
| P5 | Clinic partnerships needs the list of clinics where no doctor works, so they can recruit doctors or close the listing. The list is always empty. That is a wrong answer, not a slow one, so it is a correctness bug. | Clinic partnerships | Interactive tool (and a correctness problem) | R13 |
| P6 | Quality needs no-show rates, waiting times, doctor ratings and double bookings. These read a large share of all appointments and currently time out. The nightly no-show job belongs here too. | Quality team; doctor (ranking); clinic; patient (waits) | Reporting / analytics (W04 is a batch job) | R08, R09, R14, R24, W04 |
| P7 | Finance, pharmacy partners and population health need monthly and yearly totals. They are slow today and appointments will grow 20x, so anything that scans the whole table will be 20x slower. Support also needs to page through all appointments, and a doctor on leave must be cancelled and refunded in one action. | Finance; pharmacy partners; support; doctor; patient (refunds) | Reporting / analytics, except R21, R22, R23 and W05 which are interactive tools | R12, R15, R16, R17, R19, R20, R21, R22, R23, W05 |

## What the classification means for targets

| Class | Queries | Target on the large dataset | Why |
|-------|---------|-----------------------------|-----|
| Real-time screens | R02, R03, R04, R05, R06, R07, R23, W01, W02, W03 | under 5 ms | A person is looking at a spinner. Must be an index lookup that does not grow with the table. |
| Interactive search and tools | R01, R11, R13, R18, R21, R22, W05 | under 250 ms | Staff or patient is waiting, but a short pause is acceptable. |
| Reports and analytics | R08, R09, R10, R12, R14, R15, R16, R17, R19, R20, R24, R25 | under 5,000 ms | Nobody is blocked; these may read a large share of the table. |
| Batch job | W04 | under 1,000 ms | Runs at midnight, but holds row locks while it runs. |

## Assumptions

1. All timestamps are Indian Standard Time (the CSV files carry a `+05:30` offset). "30 June 2026" in a query means that calendar day in IST, so the database session must run with `timezone = 'Asia/Kolkata'`.
2. `weekday` uses PostgreSQL's day-of-week numbering (0 = Sunday ... 6 = Saturday). We checked this against the data: every appointment falls on the weekday of a matching schedule row. No doctor works on Sunday in the seed data.
3. A schedule row or appointment with no `clinic_id` is a video consultation, not missing data.
4. "Now" for the workload is about 1 July 2026: the data ends on 30 June 2026 and the write queries act on 1-3 July 2026.
5. Appointment rows are medical and financial records. They are cancelled, never deleted, so delete rules protect them.
6. `fee` on an appointment is the price agreed at booking time. A later change to the doctor's fee must not change past appointments.
7. Results of the 30 queries are fixed. We may change how a query is written or add indexes, but not what it returns - except R13, which returns a wrong answer today (see `docs/02_schema_design.md`, data problem 5).
8. Real-time queries matter more than reports when the two conflict, for example when an index speeds up a report but slows down booking.
