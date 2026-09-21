-- Self-service PIN reset needs a secret this app doesn't otherwise collect.
-- Name and studio role are both already public (shown on the leaderboard,
-- gallery, and projector), so a reset keyed on those alone would let anyone
-- hijack anyone else's account. Add an optional recovery phrase, collected
-- at self-registration, that only the student and the reset flow ever see.
-- Teacher-created students (via create_student) have no recovery phrase and
-- must still go through the teacher, same as today -- no regression there.

alter table public.students add column if not exists recovery_phrase text;

drop function if exists public.register_student(text, text);

create or replace function public.register_student(p_name text, p_studio_role text, p_recovery_phrase text default null)
returns table(student_id integer, assigned_pin text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pin TEXT;
  v_attempts INTEGER := 0;
  v_new_id INTEGER;
begin
  loop
    v_pin := lpad(floor(random() * 10000)::text, 4, '0');
    v_attempts := v_attempts + 1;
    exit when not exists (select 1 from students where pin_code = v_pin) or v_attempts > 30;
  end loop;

  if v_attempts > 30 then
    raise exception 'Could not generate a unique PIN, try again';
  end if;

  insert into students (name, studio_role, pin_code, recovery_phrase, approval_status, total_xp, is_active)
  values (p_name, p_studio_role, v_pin, nullif(trim(p_recovery_phrase), ''), 'Approved', 0, true)
  returning students.student_id into v_new_id;

  return query select v_new_id, v_pin;
end;
$function$;

create or replace function public.reset_my_pin(p_name text, p_recovery_phrase text)
returns table(assigned_pin text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_name_fails integer;
  v_global_fails integer;
  v_match_id integer;
  v_pin text;
  v_attempts integer := 0;
begin
  select count(*) into v_name_fails
  from auth_rate_limit_events
  where bucket = 'pin_reset_fail:' || lower(trim(p_name))
    and occurred_at > now() - interval '15 minutes';

  if v_name_fails >= 5 then
    raise exception 'Too many attempts. Please wait a while and try again, or ask your teacher.';
  end if;

  select count(*) into v_global_fails
  from auth_rate_limit_events
  where bucket = 'pin_reset_fail_global'
    and occurred_at > now() - interval '60 seconds';

  if v_global_fails >= 30 then
    raise exception 'Too many attempts right now. Please wait a moment and try again.';
  end if;

  select s.student_id into v_match_id
  from students s
  where lower(trim(s.name)) = lower(trim(p_name))
    and s.recovery_phrase is not null
    and s.recovery_phrase = p_recovery_phrase
    and s.is_active = true
    and s.approval_status = 'Approved'
  limit 1;

  if v_match_id is null then
    insert into auth_rate_limit_events (bucket) values ('pin_reset_fail:' || lower(trim(p_name)));
    insert into auth_rate_limit_events (bucket) values ('pin_reset_fail_global');
    raise exception 'Could not verify your details. Ask your teacher for help.';
  end if;

  loop
    v_pin := lpad(floor(random() * 10000)::text, 4, '0');
    v_attempts := v_attempts + 1;
    exit when not exists (select 1 from students where pin_code = v_pin) or v_attempts > 30;
  end loop;

  if v_attempts > 30 then
    raise exception 'Could not generate a unique PIN, try again';
  end if;

  update students set pin_code = v_pin where student_id = v_match_id;

  return query select v_pin;
end;
$function$;
