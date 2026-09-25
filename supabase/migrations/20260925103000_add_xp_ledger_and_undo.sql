-- Applied to production 2026-09-25.
-- XP history: every change to a student's XP is recorded, so it can be audited and undone.
-- The table is private (only the SECURITY DEFINER functions below can touch it).
create table if not exists public.xp_ledger (
  id bigint generated always as identity primary key,
  student_id integer not null references public.students (student_id) on delete cascade,
  delta integer not null,
  reason text not null,
  submission_id integer,
  reverses_id bigint references public.xp_ledger (id),
  created_at timestamptz not null default now()
);
create index if not exists idx_xp_ledger_student on public.xp_ledger (student_id, created_at desc);
alter table public.xp_ledger enable row level security;
revoke all on public.xp_ledger from anon, authenticated;

-- Backfill so the ledger adds up to each student's current XP exactly.
insert into public.xp_ledger (student_id, delta, reason, submission_id, created_at)
select s.student_id, s.xp_awarded, 'Quest approved', s.submission_id, coalesce(s.reviewed_at, now())
from public.submissions s
where s.status = 'Approved' and coalesce(s.xp_awarded, 0) > 0
  and not exists (select 1 from public.xp_ledger);

insert into public.xp_ledger (student_id, delta, reason)
select st.student_id, st.total_xp - coalesce(l.total, 0), 'Earlier adjustments'
from public.students st
left join (select student_id, sum(delta) as total from public.xp_ledger group by student_id) l using (student_id)
where st.total_xp - coalesce(l.total, 0) <> 0;

-- review_submission: same behaviour as before, plus a ledger row whenever XP changes.
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
    insert into xp_ledger (student_id, delta, reason, submission_id)
    values (v_student_id, v_new_xp - v_old_xp,
            case when v_old_xp = 0 then 'Quest approved' else 'Review changed' end,
            p_submission_id);
  end if;

  if p_status = 'Approved' then
    insert into student_badges (student_id, badge_id)
    select v_student_id, badge_id from badges where unlock_quest_id = v_quest_id
    on conflict do nothing;
  end if;
end;
$function$;

-- award_quick_xp: same behaviour, plus validation (student must exist, non-zero, +/-1000) and a ledger row.
create or replace function public.award_quick_xp(p_teacher_key text, p_student_id integer, p_xp integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  if p_xp is null or p_xp = 0 or abs(p_xp) > 1000 then
    raise exception 'XP must be between -1000 and 1000, and not zero';
  end if;

  update students set total_xp = coalesce(total_xp, 0) + p_xp where student_id = p_student_id;
  if not found then
    raise exception 'Student not found';
  end if;
  insert into xp_ledger (student_id, delta, reason) values (p_student_id, p_xp, 'Quick award');
end;
$function$;

-- Undo a review: the submission returns to Pending, its XP is taken back, and badges that only this
-- approval earned are removed.
create or replace function public.undo_review(p_teacher_key text, p_submission_id integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_student_id integer;
  v_quest_id text;
  v_status text;
  v_xp integer;
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  select student_id, quest_id, status, coalesce(xp_awarded, 0)
    into v_student_id, v_quest_id, v_status, v_xp
  from submissions
  where submission_id = p_submission_id
  for update;

  if not found then
    raise exception 'Submission not found';
  end if;
  if v_status = 'Pending Review' then
    raise exception 'This submission is already pending review';
  end if;

  if v_status = 'Approved' and v_xp <> 0 then
    update students set total_xp = coalesce(total_xp, 0) - v_xp where student_id = v_student_id;
    insert into xp_ledger (student_id, delta, reason, submission_id)
    values (v_student_id, -v_xp, 'Review undone', p_submission_id);
  end if;

  update submissions
  set status = 'Pending Review', xp_awarded = 0, feedback_note = null, reviewed_at = null
  where submission_id = p_submission_id;

  if v_status = 'Approved' then
    delete from student_badges sb
    using badges b
    where sb.badge_id = b.badge_id
      and sb.student_id = v_student_id
      and b.unlock_quest_id = v_quest_id
      and not exists (
        select 1 from submissions s2
        where s2.student_id = v_student_id and s2.quest_id = v_quest_id and s2.status = 'Approved');
  end if;
end;
$function$;

-- Undo a quick XP award (reviews are undone with undo_review instead).
create or replace function public.undo_quick_xp(p_teacher_key text, p_ledger_id bigint)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r xp_ledger%rowtype;
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  select * into r from xp_ledger where id = p_ledger_id for update;
  if not found then
    raise exception 'That XP entry was not found';
  end if;
  if r.reason <> 'Quick award' then
    raise exception 'Only quick awards can be undone here. To undo a review, use Undo on the reviewed submission.';
  end if;
  if exists (select 1 from xp_ledger where reverses_id = r.id) then
    raise exception 'That award was already undone';
  end if;

  update students set total_xp = coalesce(total_xp, 0) - r.delta where student_id = r.student_id;
  insert into xp_ledger (student_id, delta, reason, reverses_id)
  values (r.student_id, -r.delta, 'Quick award undone', r.id);
end;
$function$;

-- A student's XP history for the teacher (latest 100 entries).
create or replace function public.admin_list_xp_ledger(p_teacher_key text, p_student_id integer)
returns table(id bigint, delta integer, reason text, submission_id integer, quest_title text,
              created_at timestamptz, undone boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  return query
  select l.id, l.delta, l.reason, l.submission_id, q.title, l.created_at,
         exists (select 1 from xp_ledger r where r.reverses_id = l.id)
  from xp_ledger l
  left join submissions s on s.submission_id = l.submission_id
  left join quests q on q.quest_id = s.quest_id
  where l.student_id = p_student_id
  order by l.id desc
  limit 100;
end;
$function$;
