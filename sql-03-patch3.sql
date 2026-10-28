-- Patch 3: edit / delete a building, "Other" expense needs a name,
-- cancel any payment, remove the fees of a period, trial cannot be restarted by deleting.
-- Run once in Supabase > SQL Editor (after patch 2).

-- 1) the 30-day trial belongs to the person, so deleting and re-creating a building does not restart it
alter table public.profiles add column if not exists trial_started_at timestamptz;
update public.profiles p set trial_started_at = (select min(b.created_at) from public.buildings b where b.manager_id = p.id)
 where p.trial_started_at is null and exists (select 1 from public.buildings b where b.manager_id = p.id);

create or replace function public.create_building(p_name text, p_gov text, p_city text, p_area text, p_per int[])
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); lim int; n_have int; c text; bid uuid; i int; k int; ts timestamptz;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if coalesce(auth.jwt()->>'aal','') <> 'aal2' then raise exception 'authenticator required'; end if;
  if exists (select 1 from apartments where resident_id = uid) then raise exception 'residents cannot manage'; end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_gov),'') = '' or coalesce(trim(p_city),'') = '' or coalesce(trim(p_area),'') = '' then
    raise exception 'missing building details'; end if;
  if p_per is null or array_length(p_per,1) is null or array_length(p_per,1) > 40 then raise exception 'bad floors'; end if;
  select count(*) into n_have from buildings where manager_id = uid;
  lim := case when exists (select 1 from buildings where manager_id = uid and status = 'active') then 3 else 1 end;
  if n_have >= lim then raise exception 'license limit reached'; end if;
  select trial_started_at into ts from profiles where id = uid;
  if ts is null then ts := now(); update profiles set trial_started_at = ts where id = uid; end if;
  loop
    c := '';
    for i in 1..5 loop c := c || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random()*32)::int, 1); end loop;
    exit when not exists (select 1 from buildings where code = c);
  end loop;
  insert into buildings (manager_id, name, gov, city, area, code, trial_ends)
    values (uid, trim(p_name), trim(p_gov), trim(p_city), trim(p_area), c, ts + interval '30 days') returning id into bid;
  for i in 1..array_length(p_per,1) loop
    if p_per[i] < 1 or p_per[i] > 99 then raise exception 'bad apartment count'; end if;
    for k in 1..p_per[i] loop
      insert into apartments (building_id, code, floor) values (bid, (i*100+k)::text, i);
    end loop;
  end loop;
  perform log_it(bid, 'building', jsonb_build_object('name', p_name));
  return bid;
end $$;

-- 2) edit a building (name and place any time; floors/apartments only while there are no residents, fees or payments)
create function public.update_building(p_building uuid, p_name text, p_gov text, p_city text, p_area text, p_per int[])
returns void language plpgsql security definer set search_path = public as $$
declare i int; k int;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_gov),'') = '' or coalesce(trim(p_city),'') = '' or coalesce(trim(p_area),'') = '' then
    raise exception 'missing building details'; end if;
  update buildings set name = trim(p_name), gov = trim(p_gov), city = trim(p_city), area = trim(p_area) where id = p_building;
  if p_per is not null then
    if array_length(p_per,1) is null or array_length(p_per,1) > 40 then raise exception 'bad floors'; end if;
    if exists (select 1 from apartments where building_id = p_building and resident_id is not null)
       or exists (select 1 from charges where building_id = p_building)
       or exists (select 1 from payments where building_id = p_building) then
      raise exception 'building has data'; end if;
    delete from apartments where building_id = p_building;
    for i in 1..array_length(p_per,1) loop
      if p_per[i] < 1 or p_per[i] > 99 then raise exception 'bad apartment count'; end if;
      for k in 1..p_per[i] loop
        insert into apartments (building_id, code, floor) values (p_building, (i*100+k)::text, i);
      end loop;
    end loop;
  end if;
  perform log_it(p_building, 'edit', jsonb_build_object('name', trim(p_name)));
end $$;

-- 3) delete a building (trial buildings only; the manager must type the building name)
create function public.delete_building(p_building uuid, p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare b buildings%rowtype;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  select * into b from buildings where id = p_building;
  if b.status <> 'trial' then raise exception 'paid building cannot be deleted'; end if;
  if trim(coalesce(p_confirm,'')) <> b.name then raise exception 'name does not match'; end if;
  delete from buildings where id = p_building;
end $$;

-- photos of a deleted building can then be removed by the app
create policy "invoice delete" on storage.objects for delete to authenticated
  using (bucket_id = 'invoices' and (
    public.is_manager(((storage.foldername(name))[1])::uuid)
    or not exists (select 1 from public.buildings where id = ((storage.foldername(name))[1])::uuid)));

-- 4) "Other" expenses must have a name; the name goes to the history
create or replace function public.add_expense(p_building uuid, p_category text, p_amount numeric, p_period text, p_note text, p_invoice text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'bad amount'; end if;
  if p_category = 'oth' and coalesce(trim(p_note),'') = '' then raise exception 'name required for other'; end if;
  insert into expenses (building_id, category, amount, period, note, invoice_path, created_by)
    values (p_building, p_category, p_amount, p_period, coalesce(trim(p_note),''), p_invoice, auth.uid()) returning expenses.id into id;
  perform log_it(p_building, 'exp', jsonb_build_object('category', p_category, 'amount', p_amount, 'period', p_period, 'note', coalesce(trim(p_note),'')));
  return id;
end $$;

create or replace function public.delete_expense(p_expense uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; c text; a numeric; n text;
begin
  select building_id, category, amount, note into b, c, a, n from expenses where id = p_expense and not deleted;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  update expenses set deleted = true where id = p_expense;
  perform log_it(b, 'delexp', jsonb_build_object('category', c, 'amount', a, 'note', n));
end $$;

-- 5) undo tools. History itself stays a permanent record; every undo adds a new line to it.
create or replace function public.set_plan(p_building uuid, p_type text, p_amount numeric) returns void
language plpgsql security definer set search_path = public as $$
declare ot text; oa numeric;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if p_type not in ('monthly','yearly') or p_amount is null or p_amount <= 0 then raise exception 'bad plan'; end if;
  select plan_type, plan_amount into ot, oa from buildings where id = p_building;
  update buildings set plan_type = p_type, plan_amount = p_amount where id = p_building;
  perform log_it(p_building, 'plan', jsonb_build_object('type', p_type, 'amount', p_amount, 'old_type', ot, 'old_amount', oa));
end $$;

create function public.cancel_payment(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; a uuid; amt numeric; rc text;
begin
  select building_id, apartment_id, amount, receipt_no into b, a, amt, rc from payments where id = p_payment and not cancelled;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  update payments set cancelled = true where id = p_payment;
  perform log_it(b, 'cancel', jsonb_build_object('apartment', a, 'amount', amt, 'receipt', rc));
end $$;

-- remove the fees of one period (only if no apartment would end up having paid more than it is charged)
create function public.remove_fees(p_building uuid, p_period text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
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

revoke execute on all functions in schema public from public, anon;
grant execute on function public.update_building(uuid,text,text,text,text,int[]) to authenticated;
grant execute on function public.delete_building(uuid,text) to authenticated;
grant execute on function public.cancel_payment(uuid) to authenticated;
grant execute on function public.remove_fees(uuid,text) to authenticated;
grant execute on function public.add_expense(uuid,text,numeric,text,text,text) to authenticated;
grant execute on function public.delete_expense(uuid) to authenticated;
grant execute on function public.set_plan(uuid,text,numeric) to authenticated;
grant execute on function public.create_building(text,text,text,text,int[]) to authenticated;
-- re-grant the earlier actions (the line above revoked from PUBLIC only, these keep working)
grant execute on function public.join_building(text), public.mark_invited(uuid), public.add_fees(uuid,text), public.add_payment(uuid,numeric),
  public.cancel_last_payment(uuid), public.monthly_cash(uuid), public.set_profile(text,text), public.set_prefs(text,text), public.set_tour(text),
  public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
