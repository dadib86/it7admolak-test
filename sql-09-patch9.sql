-- Patch 9: every payment is recorded for a period (a year for yearly plans, a month for monthly plans).
--  * old years can be entered: fees and payments may use any year from 2000 up to next year.
--  * a payment can only be recorded for a period that has a fee for that apartment, and not more than what is left for that period.
-- Run once in Supabase > SQL Editor (after patch 8). Run supabase-backup.sql first.

alter table public.payments add column if not exists period text;

-- payments recorded before this patch: attach them to the latest fee period of the apartment (test data)
update public.payments p set period = (select max(c.period) from public.charges c where c.apartment_id = p.apartment_id)
 where p.period is null;

-- what is still unpaid for one apartment in one period
create or replace function public.left_in_period(p_apartment uuid, p_period text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(amount) from charges where apartment_id = p_apartment and period = p_period), 0)
       - coalesce((select sum(amount) from payments where apartment_id = p_apartment and period = p_period and not cancelled), 0) $$;
revoke all on function public.left_in_period(uuid,text) from public, anon, authenticated;

drop function if exists public.add_payment(uuid, numeric);
create function public.add_payment(p_apartment uuid, p_amount numeric, p_period text) returns text
language plpgsql security definer set search_path = public as $$
declare b uuid; rc text; due numeric; lp numeric;
begin
  select building_id into b from apartments where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'bad amount'; end if;
  if coalesce(p_period,'') = '' then raise exception 'period required'; end if;
  if not exists (select 1 from charges where apartment_id = p_apartment and period = p_period) then
    raise exception 'no fee for this period'; end if;
  lp := left_in_period(p_apartment, p_period);
  if p_amount > lp then raise exception 'amount is more than the outstanding %', lp; end if;
  due := due_of(p_apartment);
  if p_amount > due then raise exception 'amount is more than the outstanding %', due; end if;
  update buildings set rc_next = rc_next + 1 where id = b returning 'R-' || (rc_next - 1) into rc;
  insert into payments (building_id, apartment_id, amount, receipt_no, period, created_by)
    values (b, p_apartment, p_amount, rc, p_period, auth.uid());
  perform log_it(b, 'pay', jsonb_build_object('apartment', p_apartment, 'amount', p_amount, 'receipt', rc, 'period', p_period));
  return rc;
end $$;

-- fees: any year from 2000 up to next year (old data can be entered); format must match the plan
create or replace function public.add_fees(p_building uuid, p_period text) returns integer
language plpgsql security definer set search_path = public as $$
declare pl numeric; pt text; n integer; y integer;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  select plan_amount, plan_type into pl, pt from buildings where id = p_building;
  if pl is null then raise exception 'set the fee plan first'; end if;
  if (pt = 'monthly' and p_period !~ '^\d{4}-(0[1-9]|1[0-2])$') or (pt = 'yearly' and p_period !~ '^\d{4}$') then
    raise exception 'period does not match plan'; end if;
  y := left(p_period, 4)::int;
  if y < 2000 or y > extract(year from now())::int + 1 then raise exception 'period does not match plan'; end if;
  insert into charges (building_id, apartment_id, period, amount)
    select p_building, id, p_period, pl from apartments where building_id = p_building
    on conflict (apartment_id, period) do nothing;
  get diagnostics n = row_count;
  perform log_it(p_building, 'fees', jsonb_build_object('period', p_period, 'amount', pl, 'apartments', n));
  return n;
end $$;

-- removing a period's fees is blocked while any (non-cancelled) payment is recorded for that period
create or replace function public.remove_fees(p_building uuid, p_period text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if exists (select 1 from payments where building_id = p_building and period = p_period and not cancelled) then
    raise exception 'payments exist for these fees'; end if;
  if exists (
    select 1 from apartments a where a.building_id = p_building
      and coalesce((select sum(amount) from charges c where c.apartment_id = a.id and c.period <> p_period), 0)
        < coalesce((select sum(amount) from payments p where p.apartment_id = a.id and not p.cancelled), 0)
  ) then raise exception 'payments exist for these fees'; end if;
  delete from charges where building_id = p_building and period = p_period;
  get diagnostics n = row_count;
  if n = 0 then return 0; end if;
  perform log_it(p_building, 'unfees', jsonb_build_object('period', p_period, 'apartments', n));
  return n;
end $$;

-- cancel a payment: history also records which period it was for
create or replace function public.cancel_payment(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; a uuid; amt numeric; rc text; per text;
begin
  select building_id, apartment_id, amount, receipt_no, period into b, a, amt, rc, per from payments where id = p_payment and not cancelled;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  update payments set cancelled = true where id = p_payment;
  perform log_it(b, 'cancel', jsonb_build_object('apartment', a, 'amount', amt, 'receipt', rc, 'period', per));
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.add_payment(uuid,numeric,text), public.add_fees(uuid,text), public.remove_fees(uuid,text), public.cancel_payment(uuid) to authenticated;
-- keep earlier grants working
grant execute on function public.update_building(uuid,text,text,text,text,int[]), public.delete_building(uuid,text),
  public.add_expense(uuid,text,numeric,text,text,text), public.delete_expense(uuid), public.set_plan(uuid,text,numeric),
  public.create_building(text,text,text,text,int[]), public.join_building(text), public.mark_invited(uuid),
  public.cancel_last_payment(uuid), public.monthly_cash(uuid), public.set_profile(text,text),
  public.set_prefs(text,text), public.set_tour(text), public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid),
  public.submit_request(text,text), public.admin_requests(), public.admin_set_request(uuid,text,text), public.admin_set_building(uuid,text,timestamptz,text),
  public.admin_reset_manager(text), public.mark_notifs_read(), public.notify_building(uuid,uuid,text), public.owner_notify(text,text),
  public.admin_buildings(), public.admin_restore_building(uuid), public.admin_purge_building(uuid) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
