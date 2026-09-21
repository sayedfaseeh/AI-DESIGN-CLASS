create or replace function public.admin_list_reviewed_submissions(p_teacher_key text)
returns table (
  submission_id integer,
  student_id integer,
  quest_id text,
  image_or_link text,
  file_path text,
  file_type text,
  status text,
  xp_awarded integer,
  feedback_note text,
  reviewed_at timestamptz,
  student_name text,
  quest_title text
)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  return query
  select s.submission_id, s.student_id, s.quest_id, s.image_or_link, s.file_path, s.file_type,
         s.status, s.xp_awarded, s.feedback_note, s.reviewed_at,
         st.name, q.title
  from submissions s
  left join students st on st.student_id = s.student_id
  left join quests q on q.quest_id = s.quest_id
  where s.status in ('Approved', 'Needs Iteration')
  order by s.reviewed_at desc nulls last
  limit 200;
end;
$function$;
