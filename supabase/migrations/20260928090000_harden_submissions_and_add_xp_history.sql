-- Closes three gaps in how students submit work, and lets students see their own XP history.
--
-- 1) A student could submit a quest they had already completed, and the teacher could approve that second copy,
--    awarding the quest's XP twice (seen in production: student 19, quest Q1.1). Submitting also did not check
--    that the quest was open, and a double click queued two identical pending entries.
-- 2) get_my_submissions and submit_quest checked a student's PIN with no rate limit. Student ids are public, so a
--    PIN could be guessed through them without ever hitting the login lockout.
-- 3) Students could not see why their XP changed (quick awards, undone reviews); the ledger was teacher-only.
--
-- Backward compatible: every call the app makes keeps working. A wrong PIN now returns no
-- rows instead of raising, so the failed guess is recorded (a raise would roll that record back).

-- ---------- Shared PIN check with its own lockout (10 wrong PINs per student per 15 minutes) ----------
create or replace function public.student_session_ok(p_student_id integer, p_pin text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_fails integer;
begin
  select count(*) into v_fails
  from auth_rate_limit_events
  where bucket = 'student_pin_fail:' || p_student_id
    and occurred_at > now() - interval '15 minutes';

  if v_fails >= 10 then
    raise exception 'Too many attempts. Please wait a few minutes and log in again.';
  end if;

  if exists (
    select 1 from students st
    where st.student_id = p_student_id and st.pin_code = p_pin
      and st.approval_status = 'Approved' and st.is_active = true
  ) then
    return true;
  end if;

  insert into auth_rate_limit_events (bucket) values ('student_pin_fail:' || p_student_id);
  return false;
end;
$function$;

-- ---------- The student's own submissions ----------
create or replace function public.get_my_submissions(p_student_id integer, p_pin text)
returns setof submissions
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not student_session_ok(p_student_id, p_pin) then
    return;
  end if;
  return query select * from submissions s where s.student_id = p_student_id;
end;
$function$;

-- ---------- Submit (or replace a still-pending attempt) ----------
create or replace function public.submit_quest(
  p_student_id integer, p_pin text, p_quest_id text, p_image_or_link text,
  p_file_path text default null, p_file_type text default null)
returns table(submission_id integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_text text := nullif(trim(coalesce(p_image_or_link, '')), '');
  v_path text := nullif(trim(coalesce(p_file_path, '')), '');
  v_pending_id integer;
  v_new_id integer;
begin
  if not student_session_ok(p_student_id, p_pin) then
    return;
  end if;

  -- One submission call per student at a time, so a double click cannot queue two entries.
  perform 1 from students st where st.student_id = p_student_id for update;

  if not exists (select 1 from quests q where q.quest_id = p_quest_id and q.status = 'Active') then
    raise exception 'This quest is not open for submissions right now.';
  end if;

  if v_text is null and v_path is null then
    raise exception 'Add a link, a description or a file before submitting.';
  end if;
  if length(coalesce(v_text, '')) > 2000 then
    raise exception 'Your description is too long (2000 characters maximum).';
  end if;
  if v_path is not null then
    if p_file_type is null or p_file_type not in ('image', 'pdf') then
      raise exception 'Only PDF, PNG or JPEG files can be attached.';
    end if;
    -- Uploads are named "<student_id>_..." by the dashboard. Gallery file paths are public, so without this
    -- a student could attach a classmate's approved file as their own.
    if length(v_path) > 200 or left(v_path, length(p_student_id::text) + 1) <> p_student_id::text || '_' then
      raise exception 'That file could not be attached. Please upload it again.';
    end if;
  end if;

  if exists (
    select 1 from submissions s
    where s.student_id = p_student_id and s.quest_id = p_quest_id and s.status = 'Approved'
  ) then
    raise exception 'You have already completed this quest.';
  end if;

  select s.submission_id into v_pending_id
  from submissions s
  where s.student_id = p_student_id and s.quest_id = p_quest_id and s.status = 'Pending Review'
  order by s.submission_id desc
  limit 1;

  if v_pending_id is not null then
    update submissions s
    set image_or_link = v_text,
        file_path = v_path,
        file_type = case when v_path is null then null else p_file_type end
    where s.submission_id = v_pending_id;
    return query select v_pending_id;
    return;
  end if;

  insert into submissions (student_id, quest_id, image_or_link, file_path, file_type, status)
  values (p_student_id, p_quest_id, v_text, v_path,
          case when v_path is null then null else p_file_type end, 'Pending Review')
  returning submissions.submission_id into v_new_id;

  return query select v_new_id;
end;
$function$;

-- The 4-argument overload could never be called: a 4-argument call matches both it and the 6-argument version
-- (whose last two arguments have defaults), which Postgres rejects as ambiguous. Dropping it sends such calls to
-- the 6-argument version above, with the same rules.
drop function if exists public.submit_quest(integer, text, text, text);

-- ---------- Review: never approve a second copy of a completed quest ----------
create or replace function public.review_submission(
  p_teacher_key text, p_submission_id integer, p_status text,
  p_xp_awarded integer default 0, p_feedback_note text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_student_id integer;
  v_quest_id text;
  v_old_status text;
  v_old_xp integer;
  v_new_xp integer;
begin
  if not verify_teacher_key(p_teacher_key) then
    return; -- no raise, so the failed guess stays counted by the teacher-key lockout
  end if;

  if p_status not in ('Approved', 'Needs Iteration') then
    raise exception 'Invalid status';
  end if;

  select s.student_id, s.quest_id, s.status, coalesce(s.xp_awarded, 0)
    into v_student_id, v_quest_id, v_old_status, v_old_xp
  from submissions s
  where s.submission_id = p_submission_id
  for update;

  if not found then
    raise exception 'Submission not found';
  end if;

  -- Serialise reviews per student so two approvals of the same quest cannot race past the check below.
  perform 1 from students st where st.student_id = v_student_id for update;

  if p_status = 'Approved' and exists (
    select 1 from submissions s2
    where s2.student_id = v_student_id and s2.quest_id = v_quest_id
      and s2.status = 'Approved' and s2.submission_id <> p_submission_id
  ) then
    raise exception 'This student already has an approved submission for this quest. Mark this one Needs Iteration, or undo the other approval first.';
  end if;

  v_new_xp := case when p_status = 'Approved' then greatest(coalesce(p_xp_awarded, 0), 0) else 0 end;
  v_old_xp := case when v_old_status = 'Approved' then v_old_xp else 0 end;

  update submissions
  set status = p_status,
      xp_awarded = v_new_xp,
      feedback_note = p_feedback_note,
      reviewed_at = now()
  where submissions.submission_id = p_submission_id;

  if v_new_xp <> v_old_xp then
    update students set total_xp = coalesce(total_xp, 0) + (v_new_xp - v_old_xp)
    where students.student_id = v_student_id;
    insert into xp_ledger (student_id, delta, reason, submission_id)
    values (v_student_id, v_new_xp - v_old_xp,
            case when v_old_xp = 0 then 'Quest approved' else 'Review changed' end,
            p_submission_id);
  end if;

  if p_status = 'Approved' then
    insert into student_badges (student_id, badge_id)
    select v_student_id, b.badge_id from badges b where b.unlock_quest_id = v_quest_id
    on conflict do nothing;
  end if;
end;
$function$;

-- ---------- A student's own XP history (latest 50 entries) ----------
create or replace function public.get_my_xp_history(p_student_id integer, p_pin text)
returns table(delta integer, reason text, quest_title text, created_at timestamptz, undone boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not student_session_ok(p_student_id, p_pin) then
    return;
  end if;

  return query
  select l.delta, l.reason, q.title, l.created_at,
         exists (select 1 from xp_ledger r where r.reverses_id = l.id)
  from xp_ledger l
  left join submissions s on s.submission_id = l.submission_id
  left join quests q on q.quest_id = s.quest_id
  where l.student_id = p_student_id
  order by l.id desc
  limit 50;
end;
$function$;
