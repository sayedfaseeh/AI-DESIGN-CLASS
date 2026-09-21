create or replace function public.bulk_create_students(p_teacher_key text, p_students jsonb)
returns table(name text, assigned_pin text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  rec jsonb;
  v_pin text;
  v_attempts integer;
begin
  if not verify_teacher_key(p_teacher_key) then
    raise exception 'Invalid teacher key';
  end if;

  if p_students is null or jsonb_array_length(p_students) = 0 then
    raise exception 'No students to import';
  end if;

  for rec in select * from jsonb_array_elements(p_students)
  loop
    v_attempts := 0;
    loop
      v_pin := lpad(floor(random() * 10000)::text, 4, '0');
      v_attempts := v_attempts + 1;
      exit when not exists (select 1 from students where pin_code = v_pin) or v_attempts > 30;
    end loop;

    if v_attempts > 30 then
      raise exception 'Could not generate a unique PIN for %', rec->>'name';
    end if;

    insert into students (name, studio_role, pin_code, approval_status, total_xp, is_active)
    values (rec->>'name', rec->>'studio_role', v_pin, 'Approved', 0, true);

    name := rec->>'name';
    assigned_pin := v_pin;
    return next;
  end loop;
end;
$function$;
