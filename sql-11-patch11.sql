-- Patch 11: flexible payments + settled / exempt apartments (for example shops).
--  * the amount paid can be more or less than the fee (extra money stays as credit for the apartment).
--  * the manager can mark one fee period of an apartment as "settled" (even if the amount paid is different), with a note.
--  * the manager can mark a whole apartment as "exempt" (a shop, for example): its fees are settled automatically, now and for new fees.
-- Run once in Supabase > SQL Editor (after patch 10). Run supabase-backup.sql first. Safe to run twice.

alter table public.charges add column if not exists settled boolean not null default false;
alter table public.charges add column if not exists settled_note text not null default '';
alter table public.charges add column if not exists settled_auto boolean not null default false;
alter table public.apartments add column if not exists exempt boolean not null default false;
alter table public.apartments add column if not exists exempt_note text not null default '';

-- what is paid in one period
create or replace function public.paid_in_period(p_apartment uuid, p_period text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(amount) from payments where apartment_id = p_apartment and period = p_period and not cancelled), 0) $$;
revoke all on function public.paid_in_period(uuid,text) from public, anon, authenticated;

-- what is still owed by an apartment: settled periods count as fully settled
create or replace function public.due_of(p_apartment uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((select sum(case when c.settled then paid_in_period(c.apartment_id, c.period) else c.amount end)
              from charges c where c.apartment_id = p_apartment), 0)
  - coalesce((select sum(amount) from payments where apartment_id = p_apartment and not cancelled), 0), 0) $$;
revoke all on function public.due_of(uuid) from public, anon, authenticated;

-- record a payment: any amount (more or less than the fee)
create or replace function public.add_payment(p_apartment uuid, p_amount numeric, p_period text) returns text
language plpgsql security definer set search_path = public as $$
declare b uuid; rc text;
begin
  select building_id into b from apartments where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000000 then raise exception 'bad amount'; end if;
  if coalesce(p_period,'') = '' then raise exception 'period required'; end if;
  if not exists (select 1 from charges where apartment_id = p_apartment and period = p_period) then
    raise exception 'no fee for this period'; end if;
  update buildings set rc_next = rc_next + 1 where id = b returning 'R-' || (rc_next - 1) into rc;
  insert into payments (building_id, apartment_id, amount, receipt_no, period, created_by)
    values (b, p_apartment, p_amount, rc, p_period, auth.uid());
  perform log_it(b, 'pay', jsonb_build_object('apartment', p_apartment, 'amount', p_amount, 'receipt', rc, 'period', p_period));
  return rc;
end $$;

-- fees for all apartments (exempt apartments get theirs already settled)
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
  insert into charges (building_id, apartment_id, period, amount, settled, settled_auto, settled_note)
    select p_building, id, p_period, pl, exempt, exempt, case when exempt then exempt_note else '' end
      from apartments where building_id = p_building
    on conflict (apartment_id, period) do nothing;
  get diagnostics n = row_count;
  perform log_it(p_building, 'fees', jsonb_build_object('period', p_period, 'amount', pl, 'apartments', n));
  return n;
end $$;

-- mark one period of one apartment as settled (or undo it)
create or replace function public.settle_period(p_apartment uuid, p_period text, p_on boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; acode text;
begin
  select building_id, a.code into b, acode from apartments a where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if not exists (select 1 from charges where apartment_id = p_apartment and period = p_period) then
    raise exception 'no fee for this period'; end if;
  update charges set settled = coalesce(p_on, true), settled_auto = false,
         settled_note = case when coalesce(p_on, true) then left(coalesce(trim(p_note),''), 200) else '' end
   where apartment_id = p_apartment and period = p_period;
  perform log_it(b, case when coalesce(p_on, true) then 'settle' else 'unsettle' end,
    jsonb_build_object('apartment', acode, 'period', p_period, 'note', left(coalesce(trim(p_note),''), 200)));
end $$;

-- mark a whole apartment as exempt (shop) or normal again
create or replace function public.set_exempt(p_apartment uuid, p_on boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; acode text; nt text := left(coalesce(trim(p_note),''), 200);
begin
  select building_id, a.code into b, acode from apartments a where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if coalesce(p_on, true) then
    update apartments set exempt = true, exempt_note = nt where id = p_apartment;
    update charges set settled = true, settled_auto = true, settled_note = nt where apartment_id = p_apartment and not settled;
  else
    update apartments set exempt = false, exempt_note = '' where id = p_apartment;
    update charges set settled = false, settled_auto = false, settled_note = '' where apartment_id = p_apartment and settled_auto;
  end if;
  perform log_it(b, case when coalesce(p_on, true) then 'exempt' else 'unexempt' end, jsonb_build_object('apartment', acode, 'note', nt));
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.request_transfer(uuid,text,text), public.cancel_transfer(uuid), public.answer_transfer(uuid,boolean),
  public.admin_transfer_building(uuid,text) to authenticated;
grant execute on function public.update_building(uuid,text,text,text,text,int[]), public.delete_building(uuid,text),
  public.add_expense(uuid,text,numeric,text,text,text), public.delete_expense(uuid), public.set_plan(uuid,text,numeric),
  public.create_building(text,text,text,text,int[]), public.join_building(text), public.mark_invited(uuid),
  public.cancel_last_payment(uuid), public.monthly_cash(uuid), public.set_profile(text,text),
  public.set_prefs(text,text), public.set_tour(text), public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid),
  public.submit_request(text,text), public.admin_requests(), public.admin_set_request(uuid,text,text), public.admin_set_building(uuid,text,timestamptz,text),
  public.admin_reset_manager(text), public.mark_notifs_read(), public.notify_building(uuid,uuid,text), public.owner_notify(text,text),
  public.admin_buildings(), public.admin_restore_building(uuid), public.admin_purge_building(uuid),
  public.add_payment(uuid,numeric,text), public.add_fees(uuid,text), public.remove_fees(uuid,text), public.cancel_payment(uuid),
  public.settle_period(uuid,text,boolean,text), public.set_exempt(uuid,boolean,text) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
