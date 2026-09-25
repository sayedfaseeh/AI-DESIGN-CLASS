-- Applied to production 2026-09-25.
-- reset_my_pin recorded each failed attempt and then raised an exception. The exception rolls back the
-- whole call, including the record of the failed attempt, so the limiter never counted anything.
-- Now a failed attempt is recorded and the function returns no rows (the login page already shows a
-- generic "Something went wrong" for both an error and an empty result). Matching logic is unchanged.
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
    return; -- no rows; do NOT raise here or the two inserts above would be rolled back
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
