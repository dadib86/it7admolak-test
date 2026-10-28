-- Patch 8: the fee plan type (monthly / yearly) is locked once fees exist.
--  * monthly fees use a month (2026-10), yearly fees use a year (2026): the two can never mix in one building.
--  * to switch type: cancel the payments, remove all fees, then change the plan (history records every step).
-- Run once in Supabase > SQL Editor (after patch 7). Run supabase-backup.sql first.

create or replace function public.set_plan(p_building uuid, p_type text, p_amount numeric) returns void
language plpgsql security definer set search_path = public as $$
declare ot text; oa numeric;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if p_type not in ('monthly','yearly') or p_amount is null or p_amount <= 0 then raise exception 'bad plan'; end if;
  select plan_type, plan_amount into ot, oa from buildings where id = p_building;
  if ot is not null and ot <> p_type and exists (select 1 from charges where building_id = p_building) then
    raise exception 'plan type locked'; end if;
  update buildings set plan_type = p_type, plan_amount = p_amount where id = p_building;
  perform log_it(p_building, 'plan', jsonb_build_object('type', p_type, 'amount', p_amount, 'old_type', ot, 'old_amount', oa));
end $$;

create or replace function public.add_fees(p_building uuid, p_period text) returns integer
language plpgsql security definer set search_path = public as $$
declare pl numeric; pt text; n integer;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  select plan_amount, plan_type into pl, pt from buildings where id = p_building;
  if pl is null then raise exception 'set the fee plan first'; end if;
  if (pt = 'monthly' and p_period !~ '^\d{4}-(0[1-9]|1[0-2])$') or (pt = 'yearly' and p_period !~ '^\d{4}$') then
    raise exception 'period does not match plan'; end if;
  insert into charges (building_id, apartment_id, period, amount)
    select p_building, id, p_period, pl from apartments where building_id = p_building
    on conflict (apartment_id, period) do nothing;
  get diagnostics n = row_count;
  perform log_it(p_building, 'fees', jsonb_build_object('period', p_period, 'amount', pl, 'apartments', n));
  return n;
end $$;

revoke execute on function public.set_plan(uuid,text,numeric), public.add_fees(uuid,text) from public, anon;
grant execute on function public.set_plan(uuid,text,numeric), public.add_fees(uuid,text) to authenticated;
