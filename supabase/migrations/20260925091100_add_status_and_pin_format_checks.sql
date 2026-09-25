-- Applied to production 2026-09-25. Data-integrity checks (existing data already conformed).
alter table public.submissions
  add constraint submissions_status_check
  check (status in ('Pending Review', 'Approved', 'Needs Iteration'));

alter table public.quests
  add constraint quests_status_check
  check (status in ('Active', 'Inactive'));

alter table public.students
  add constraint students_pin_format_check
  check (pin_code is null or pin_code ~ '^[0-9]{4}$');
