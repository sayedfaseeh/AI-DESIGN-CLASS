-- submissions had no timestamp columns at all, so there was no way to know
-- WHEN a submission was approved -- needed for the projector's "gained the
-- most XP in the last 24h" spotlight, and useful generally for a reviewed
-- history. Existing already-reviewed rows get backfilled to now() since
-- their real review time was never tracked; this means the 24h spotlight
-- will look unusually busy for the first 24h after this migration, then
-- self-correct as those backfilled timestamps age out of the window.

alter table public.submissions add column if not exists reviewed_at timestamptz;

create or replace function public.review_submission(p_teacher_key text, p_submission_id integer, p_status text, p_xp_awarded integer default 0, p_feedback_note text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_student_id INTEGER;
  v_quest_id TEXT;
  v_badge_id TEXT;
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  if p_status not in ('Approved', 'Needs Iteration') then
    raise exception 'Invalid status';
  end if;

  update submissions
  set status = p_status,
      xp_awarded = case when p_status = 'Approved' then p_xp_awarded else 0 end,
      feedback_note = p_feedback_note,
      reviewed_at = now()
  where submission_id = p_submission_id
  returning student_id, quest_id into v_student_id, v_quest_id;

  if p_status = 'Approved' then
    update students set total_xp = total_xp + p_xp_awarded where student_id = v_student_id;

    select badge_id into v_badge_id from badges where unlock_quest_id = v_quest_id;
    if v_badge_id is not null then
      insert into student_badges (student_id, badge_id)
      values (v_student_id, v_badge_id)
      on conflict do nothing;
    end if;
  end if;
end;
$function$;

update public.submissions set reviewed_at = now() where status in ('Approved', 'Needs Iteration') and reviewed_at is null;
