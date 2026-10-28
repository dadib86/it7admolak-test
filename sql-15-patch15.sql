-- Patch 15: a different yearly/monthly fee for one apartment (for example an apartment that is not used pays less).
--  * "own fee" is saved on the apartment; every new fee period uses it instead of the building plan.
--  * saving it also corrects fee periods that have no payment yet. Periods that already have payments are not touched.
--  * removing it puts the apartment back on the building plan.
-- Run once in Supabase > SQL Editor (after patch 14). Safe to run twice.

alter table public.apartments add column if not exists custom_fee numeric check (custom_fee is null or custom_fee > 0);

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
    select p_building, id, p_period, coalesce(custom_fee, pl), exempt, exempt, case when exempt then exempt_note else '' end
      from apartments where building_id = p_building
    on conflict (apartment_id, period) do nothing;
  get diagnostics n = row_count;
  perform log_it(p_building, 'fees', jsonb_build_object('period', p_period, 'amount', pl, 'apartments', n));
  return n;
end $$;

create or replace function public.set_apt_fee(p_apartment uuid, p_amount numeric) returns integer
language plpgsql security definer set search_path = public as $$
declare b uuid; acode text; pl numeric; n integer;
begin
  select building_id, a.code into b, acode from apartments a where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if p_amount is not null and (p_amount <= 0 or p_amount > 100000000) then raise exception 'bad amount'; end if;
  select plan_amount into pl from buildings where id = b;
  update apartments set custom_fee = p_amount where id = p_apartment;
  update charges c set amount = coalesce(p_amount, pl)
   where c.apartment_id = p_apartment and not c.settled and coalesce(p_amount, pl) is not null
     and not exists (select 1 from payments p where p.apartment_id = c.apartment_id and p.period = c.period and not p.cancelled);
  get diagnostics n = row_count;
  perform log_it(b, 'aptfee', jsonb_build_object('apartment', acode, 'amount', p_amount, 'periods', n));
  return n;
end $$;
grant execute on function public.set_apt_fee(uuid, numeric) to authenticated;
