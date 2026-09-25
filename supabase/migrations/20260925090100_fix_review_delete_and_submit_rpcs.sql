-- APPLIED to production on 2026-09-25 and verified. Three logic bugs found by reading the function definitions.
-- Signatures, SECURITY DEFINER and search_path are unchanged, so existing grants and
-- frontend calls keep working.

-- 1) review_submission: re-reviewing an already Approved submission awarded the XP again.
--    Now adjusts total_xp by the difference, rejects unknown ids and negative XP,
--    and awards every badge tied to the quest.
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
    raise exception 'Invalid teacher key';
  end if;

  if p_status not in ('Approved', 'Needs Iteration') then
    raise exception 'Invalid status';
  end if;

  select student_id, quest_id, status, coalesce(xp_awarded, 0)
    into v_student_id, v_quest_id, v_old_status, v_old_xp
  from submissions
  where submission_id = p_submission_id
  for update;

  if not found then
    raise exception 'Submission not found';
  end if;

  v_new_xp := case when p_status = 'Approved' then greatest(coalesce(p_xp_awarded, 0), 0) else 0 end;
  v_old_xp := case when v_old_status = 'Approved' then v_old_xp else 0 end;

  update submissions
  set status = p_status,
      xp_awarded = v_new_xp,
      feedback_note = p_feedback_note,
      reviewed_at = now()
  where submission_id = p_submission_id;

  if v_new_xp <> v_old_xp then
    update students set total_xp = coalesce(total_xp, 0) + (v_new_xp - v_old_xp)
    where student_id = v_student_id;
  end if;

  if p_status = 'Approved' then
    insert into student_badges (student_id, badge_id)
    select v_student_id, badge_id from badges where unlock_quest_id = v_quest_id
    on conflict do nothing;
  end if;
end;
$function$;

-- 2) delete_student: failed with an FK error for any student who had earned a badge.
create or replace function public.delete_student(p_teacher_key text, p_student_id integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  delete from student_badges where student_id = p_student_id;
  delete from submissions where student_id = p_student_id;
  delete from students where student_id = p_student_id;
end;
$function$;

-- 3) submit_quest (4-arg overload): did not check approval_status / is_active,
--    unlike the 6-arg version, so a deactivated student could still submit.
create or replace function public.submit_quest(
  p_student_id integer, p_pin text, p_quest_id text, p_image_or_link text)
returns table(submission_id integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_valid boolean;
  v_new_id integer;
begin
  select exists(
    select 1 from students
    where student_id = p_student_id and pin_code = p_pin
      and approval_status = 'Approved' and is_active = true
  ) into v_valid;

  if not v_valid then
    raise exception 'Invalid student credentials';
  end if;

  insert into submissions (student_id, quest_id, image_or_link, status)
  values (p_student_id, p_quest_id, p_image_or_link, 'Pending Review')
  returning submissions.submission_id into v_new_id;

  return query select v_new_id;
end;
$function$;
