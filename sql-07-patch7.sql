-- Patch 7: a building manager can delete any of their buildings (trial or paid).
-- The delete is safe: the building is only hidden and the app owner can restore it (patch 6).
-- Run once in Supabase > SQL Editor (after patch 6). Run supabase-backup.sql first.
create or replace function public.delete_building(p_building uuid, p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare b buildings%rowtype;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  select * into b from buildings where id = p_building;
  if trim(coalesce(p_confirm,'')) <> b.name then raise exception 'name does not match'; end if;
  perform log_it(p_building, 'deleted', jsonb_build_object('name', b.name, 'status', b.status));
  update buildings set deleted_at = now() where id = p_building;
end $$;
revoke execute on function public.delete_building(uuid,text) from public, anon;
grant execute on function public.delete_building(uuid,text) to authenticated;
