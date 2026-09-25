-- Applied to production 2026-09-25. Covering indexes for foreign keys (flagged by the performance advisor).
create index if not exists idx_submissions_student_id on public.submissions (student_id);
create index if not exists idx_submissions_quest_id on public.submissions (quest_id);
create index if not exists idx_student_badges_badge_id on public.student_badges (badge_id);
