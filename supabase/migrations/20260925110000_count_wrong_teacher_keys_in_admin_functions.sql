-- Applied to production 2026-09-25.
-- The teacher-key lockout only counted wrong guesses made through verify_teacher_key directly. Every admin
-- function checked the key and then RAISED on failure, and a raise rolls back the whole request, including the
-- failed-guess record that verify_teacher_key had just written. So wrong keys sent to any admin function were
-- never counted and could be guessed without limit.
--
-- Fix: on an invalid key these functions now simply return (no rows / no effect) instead of raising, so the
-- failed-guess record is kept and the existing lockout (10 failures per 15 minutes) applies to them too.
-- A valid key behaves exactly as before. The login screen is unaffected (it uses verify_teacher_key).
-- Idempotent: once applied, no function contains the raise any more, so re-running changes nothing.
do $$
declare
  r record;
  newdef text;
  n integer := 0;
begin
  for r in
    select p.oid, pg_get_functiondef(p.oid) as def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.prokind = 'f'
      and pg_get_functiondef(p.oid) ~* 'raise\s+exception\s+''Invalid teacher key''\s*;'
  loop
    newdef := regexp_replace(r.def, 'raise\s+exception\s+''Invalid teacher key''\s*;', 'return;', 'gi');
    execute newdef;
    n := n + 1;
  end loop;
  raise notice 'updated % functions', n;
end $$;
