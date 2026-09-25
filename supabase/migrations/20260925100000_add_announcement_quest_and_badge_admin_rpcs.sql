-- Applied to production 2026-09-25.
-- Teacher tools that previously needed SQL access: class announcement, quest and badge management.
-- Every write function checks the teacher key first (same pattern as the existing admin RPCs).

-- ---------- Announcement (shown on the student dashboard) ----------
create or replace function public.get_announcement()
returns table(message text)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  return query select coalesce((select value from app_config where key = 'announcement'), '');
end;
$function$;

create or replace function public.set_announcement(p_teacher_key text, p_message text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  if length(coalesce(p_message, '')) > 300 then
    raise exception 'The announcement is too long (300 characters maximum)';
  end if;
  insert into app_config (key, value) values ('announcement', trim(coalesce(p_message, '')))
  on conflict (key) do update set value = excluded.value;
end;
$function$;

-- ---------- Quests ----------
create or replace function public.admin_save_quest(
  p_teacher_key text, p_quest_id text, p_title text, p_points_xp integer, p_required_tool text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  if p_quest_id is null or p_quest_id !~ '^[A-Za-z0-9._-]{1,20}$' then
    raise exception 'Quest ID must be 1-20 letters, numbers, dots, dashes or underscores';
  end if;
  if p_title is null or length(trim(p_title)) = 0 or length(p_title) > 120 then
    raise exception 'Enter a title (120 characters maximum)';
  end if;
  if p_points_xp is null or p_points_xp < 0 or p_points_xp > 1000 then
    raise exception 'XP must be between 0 and 1000';
  end if;
  if length(coalesce(p_required_tool, '')) > 80 then
    raise exception 'Tool name is too long (80 characters maximum)';
  end if;

  -- New quests start Inactive so students do not see them until the teacher activates them.
  insert into quests (quest_id, title, points_xp, required_tool, status)
  values (p_quest_id, trim(p_title), p_points_xp, nullif(trim(coalesce(p_required_tool, '')), ''), 'Inactive')
  on conflict (quest_id) do update
    set title = excluded.title, points_xp = excluded.points_xp, required_tool = excluded.required_tool;
end;
$function$;

create or replace function public.admin_delete_quest(p_teacher_key text, p_quest_id text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  if exists (select 1 from submissions where quest_id = p_quest_id) then
    raise exception 'This quest already has submissions. Deactivate it instead of deleting it.';
  end if;
  if exists (select 1 from badges where unlock_quest_id = p_quest_id) then
    raise exception 'A badge is linked to this quest. Change or delete that badge first.';
  end if;
  delete from quests where quest_id = p_quest_id;
end;
$function$;

-- ---------- Badges ----------
create or replace function public.admin_save_badge(
  p_teacher_key text, p_badge_id text, p_title text, p_icon text, p_description text,
  p_unlock_quest_id text, p_sort_order integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  if p_badge_id is null or p_badge_id !~ '^[A-Za-z0-9_-]{1,30}$' then
    raise exception 'Badge ID must be 1-30 letters, numbers, dashes or underscores';
  end if;
  if p_title is null or length(trim(p_title)) = 0 or length(p_title) > 60 then
    raise exception 'Enter a badge title (60 characters maximum)';
  end if;
  if p_icon is null or length(trim(p_icon)) = 0 or length(p_icon) > 8 then
    raise exception 'Enter one emoji or short symbol as the icon';
  end if;
  if length(coalesce(p_description, '')) > 200 then
    raise exception 'Description is too long (200 characters maximum)';
  end if;
  if nullif(trim(coalesce(p_unlock_quest_id, '')), '') is not null
     and not exists (select 1 from quests where quest_id = trim(p_unlock_quest_id)) then
    raise exception 'The unlock quest does not exist';
  end if;

  insert into badges (badge_id, title, icon, description, unlock_quest_id, sort_order)
  values (p_badge_id, trim(p_title), trim(p_icon), nullif(trim(coalesce(p_description, '')), ''),
          nullif(trim(coalesce(p_unlock_quest_id, '')), ''), coalesce(p_sort_order, 0))
  on conflict (badge_id) do update
    set title = excluded.title, icon = excluded.icon, description = excluded.description,
        unlock_quest_id = excluded.unlock_quest_id, sort_order = excluded.sort_order;
end;
$function$;

create or replace function public.admin_delete_badge(p_teacher_key text, p_badge_id text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;
  delete from student_badges where badge_id = p_badge_id;
  delete from badges where badge_id = p_badge_id;
end;
$function$;
