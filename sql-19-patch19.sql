-- Patch 19: rename apartments (for example 101 -> 1A, or swap 101 and 102), even in a running building.
--  * only the name changes: residents, fees and payments stay with the same apartment.
--  * names: letters and numbers only, up to 8 characters, not used by another apartment of the building.
--  * an old invite code that used the old name stops working, so send the new code to anyone not joined yet.
-- Run once in Supabase > SQL Editor (after patch 18). Safe to run twice.

create or replace function public.rename_apartments(p_building uuid, p_ids uuid[], p_codes text[]) returns void
language plpgsql security definer set search_path = public as $$
declare i int; n int; c text; seen text[] := '{}'; r record;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  n := coalesce(array_length(p_ids,1), 0);
  if n = 0 or n <> coalesce(array_length(p_codes,1), 0) or n > 99 then raise exception 'bad apartment name'; end if;
  for i in 1..n loop
    c := upper(trim(p_codes[i]));
    if c !~ '^[A-Z0-9]{1,8}$' then raise exception 'bad apartment name'; end if;
    if c = any(seen) then raise exception 'apartment name exists'; end if;
    seen := seen || c;
    if not exists (select 1 from apartments where id = p_ids[i] and building_id = p_building) then raise exception 'not allowed'; end if;
    -- used by another apartment that is not being renamed in this same save
    if exists (select 1 from apartments where building_id = p_building and code = c and not (id = any(p_ids))) then raise exception 'apartment name exists'; end if;
  end loop;
  -- two steps so that names can be swapped
  update apartments set code = '~' || id::text where id = any(p_ids) and building_id = p_building;
  for i in 1..n loop
    update apartments set code = upper(trim(p_codes[i])) where id = p_ids[i];
  end loop;
  perform log_it(p_building, 'rename', jsonb_build_object('count', n));
end $$;
grant execute on function public.rename_apartments(uuid,uuid[],text[]) to authenticated;
