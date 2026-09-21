alter table public.students add column if not exists last_login_date date;
alter table public.students add column if not exists streak_count integer not null default 0;

create or replace view public.students_directory as
select student_id, name, studio_role, avatar_url, total_xp, tier_level, is_active, created_at, streak_count
from public.students;

grant select on public.students_directory to anon, authenticated;

drop function if exists public.student_login(text);

create or replace function public.student_login(p_pin text)
returns table(student_id integer, name text, studio_role text, avatar_url text, total_xp integer, tier_level text, streak_count integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_per_pin_fails integer;
  v_global_fails integer;
  v_match_id integer;
  v_last_login date;
  v_streak integer;
begin
  select count(*) into v_per_pin_fails
  from auth_rate_limit_events
  where bucket = 'student_login_fail:' || p_pin
    and occurred_at > now() - interval '5 minutes';

  if v_per_pin_fails >= 5 then
    raise exception 'Too many attempts for this PIN. Please wait a few minutes and try again.';
  end if;

  select count(*) into v_global_fails
  from auth_rate_limit_events
  where bucket = 'student_login_fail_global'
    and occurred_at > now() - interval '60 seconds';

  if v_global_fails >= 60 then
    raise exception 'Too many login attempts right now. Please wait a moment and try again.';
  end if;

  select s.student_id, s.last_login_date, s.streak_count
  into v_match_id, v_last_login, v_streak
  from students s
  where s.pin_code = p_pin and s.approval_status = 'Approved' and s.is_active = true
  limit 1;

  if v_match_id is null then
    insert into auth_rate_limit_events (bucket) values ('student_login_fail:' || p_pin);
    insert into auth_rate_limit_events (bucket) values ('student_login_fail_global');
    if random() < 0.01 then
      delete from auth_rate_limit_events where occurred_at < now() - interval '1 day';
    end if;
    return;
  end if;

  if v_last_login is null or v_last_login < current_date - 1 then
    v_streak := 1;
  elsif v_last_login = current_date - 1 then
    v_streak := v_streak + 1;
  end if;
  -- v_last_login = current_date: already logged in today, streak unchanged

  update students set last_login_date = current_date, streak_count = v_streak where students.student_id = v_match_id;

  return query
  select s.student_id, s.name, s.studio_role, s.avatar_url, s.total_xp, s.tier_level, s.streak_count
  from students s
  where s.student_id = v_match_id;
end;
$function$;
