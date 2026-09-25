-- APPLIED to production on 2026-09-25 and verified. Fixes a verified vulnerability.
--
-- students_directory is intentionally SECURITY DEFINER (it hides pin_code / recovery_phrase),
-- but it is owned by postgres (bypasses RLS), is auto-updatable, and anon/authenticated hold
-- INSERT/UPDATE/DELETE on it. Verified in a rolled-back test: the anon role updated all 3
-- student rows through the view (e.g. anyone with the public key could set total_xp or
-- delete students).
--
-- This only removes privileges. Reads and every RPC keep working, because the app writes
-- exclusively through SECURITY DEFINER functions (which run as the owner, not anon).

revoke insert, update, delete, truncate, references, trigger
  on public.students_directory from anon, authenticated;

-- Defense in depth: API roles never write tables directly. RLS already denies these
-- (no write policies exist), so this changes no behaviour.
revoke insert, update, delete, truncate, references, trigger
  on public.students, public.quests, public.submissions, public.app_config,
     public.badges, public.student_badges, public.prompts, public.auth_rate_limit_events
  from anon, authenticated;

-- Tables with no RLS policies are not meant to be read directly (app_config holds the teacher key).
revoke select on public.students, public.app_config, public.auth_rate_limit_events
  from anon, authenticated;
