-- Patch 14: the manager can remove the resident of an apartment (for example when it was sold),
-- so that the new owner can join with the apartment code. Old payments and history stay.
-- Run once in Supabase > SQL Editor (after patch 13). Safe to run twice.
create or replace function public.unlink_resident(p_apartment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; acode text; r uuid; bn text;
begin
  select building_id, a.code, resident_id into b, acode, r from apartments a where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if r is null then raise exception 'no resident'; end if;
  update apartments set resident_id = null, invited = false where id = p_apartment;
  select name into bn from buildings where id = b;
  insert into notifications (user_id, building_id, kind, data) values (r, b, 'unlinked', jsonb_build_object('building', bn, 'apt', acode));
  perform log_it(b, 'unlink', jsonb_build_object('apartment', acode));
end $$;
grant execute on function public.unlink_resident(uuid) to authenticated;
