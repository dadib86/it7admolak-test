-- Patch 18: change the number of apartments on ONE floor, safely, even in a running building.
--  * adding apartments is always allowed (new codes continue the numbering, for example 105, 106, or G3).
--  * removing apartments removes the highest numbers first, and only if they have no resident, no fees and no payments.
--  * a new floor can be added on top (the next floor number).
-- Run once in Supabase > SQL Editor (after patch 17). Safe to run twice.

create or replace function public.set_floor_count(p_building uuid, p_floor int, p_count int) returns void
language plpgsql security definer set search_path = public as $$
declare cur int; k int; mx int; r record;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if p_floor is null or p_floor < 0 or p_floor > 40 or p_count is null or p_count < 0 or p_count > 99 then raise exception 'bad apartment count'; end if;
  select coalesce(max(floor), 0) into mx from apartments where building_id = p_building;
  if p_floor > mx + 1 then raise exception 'bad floors'; end if;
  select count(*) into cur from apartments where building_id = p_building and floor = p_floor;
  if p_count > cur then
    for k in cur + 1 .. p_count loop
      insert into apartments (building_id, code, floor)
        values (p_building, case when p_floor = 0 then 'G' || k else (p_floor * 100 + k)::text end, p_floor)
        on conflict (building_id, code) do nothing;
    end loop;
  elsif p_count < cur then
    for r in select a.id from apartments a where a.building_id = p_building and a.floor = p_floor
             order by length(a.code) desc, a.code desc limit (cur - p_count) loop
      if exists (select 1 from apartments where id = r.id and resident_id is not null)
         or exists (select 1 from charges where apartment_id = r.id)
         or exists (select 1 from payments where apartment_id = r.id) then
        raise exception 'building has data'; end if;
      delete from apartments where id = r.id;
    end loop;
  end if;
  perform log_it(p_building, 'floor', jsonb_build_object('floor', p_floor, 'count', p_count));
end $$;
grant execute on function public.set_floor_count(uuid,int,int) to authenticated;
