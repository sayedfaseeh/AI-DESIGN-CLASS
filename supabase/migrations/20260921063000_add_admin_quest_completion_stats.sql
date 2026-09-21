create or replace function public.admin_quest_completion_stats(p_teacher_key text)
returns table(quest_id text, title text, approved_count bigint)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  return query
  select q.quest_id, q.title, count(s.submission_id) filter (where s.status = 'Approved') as approved_count
  from quests q
  left join submissions s on s.quest_id = q.quest_id
  group by q.quest_id, q.title
  order by approved_count desc, q.quest_id;
end;
$function$;
