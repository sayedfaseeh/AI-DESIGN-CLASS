-- Applied to production 2026-09-25. register_student is callable by anyone with the public key, so it now
-- validates input and caps sign-ups (60 per 10 minutes) so nobody can flood the roster or use up the
-- 4-digit PIN space. Signature and PIN logic are unchanged.
create or replace function public.register_student(
  p_name text, p_studio_role text, p_recovery_phrase text default null)
returns table(student_id integer, assigned_pin text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pin text;
  v_attempts integer := 0;
  v_new_id integer;
  v_recent integer;
begin
  if p_name is null or length(trim(p_name)) = 0 or length(p_name) > 80
     or length(coalesce(p_studio_role, '')) > 80
     or length(coalesce(p_recovery_phrase, '')) > 200 then
    raise exception 'Please enter a valid name and role';
  end if;

  -- Class-sized cap so nobody can flood the roster or use up the 4-digit PIN space.
  select count(*) into v_recent
  from auth_rate_limit_events
  where bucket = 'register_student' and occurred_at > now() - interval '10 minutes';

  if v_recent >= 60 then
    raise exception 'Too many sign-ups right now. Please wait a few minutes or ask your teacher.';
  end if;

  loop
    v_pin := lpad(floor(random() * 10000)::text, 4, '0');
    v_attempts := v_attempts + 1;
    exit when not exists (select 1 from students where pin_code = v_pin) or v_attempts > 30;
  end loop;

  if v_attempts > 30 then
    raise exception 'Could not generate a unique PIN, try again';
  end if;

  insert into students (name, studio_role, pin_code, recovery_phrase, approval_status, total_xp, is_active)
  values (trim(p_name), p_studio_role, v_pin, nullif(trim(p_recovery_phrase), ''), 'Approved', 0, true)
  returning students.student_id into v_new_id;

  insert into auth_rate_limit_events (bucket) values ('register_student');
  if random() < 0.05 then
    delete from auth_rate_limit_events where occurred_at < now() - interval '1 day';
  end if;

  return query select v_new_id, v_pin;
end;
$function$;
