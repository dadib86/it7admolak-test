-- it7ad molak | إتحاد ملاك : database setup (run once in Supabase > SQL Editor)
-- Rule of this design: the app can NEVER write tables directly.
-- Every change goes through a function below that checks who you are,
-- that your license is active, and writes the change history.

create extension if not exists pgcrypto;

-- ---------- tables ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  mobile text not null default '',
  email text not null default '',
  created_at timestamptz not null default now()
);

create table public.app_admins (user_id uuid primary key references auth.users(id) on delete cascade);

create table public.buildings (
  id uuid primary key default gen_random_uuid(),
  manager_id uuid not null references public.profiles(id),
  name text not null,
  gov text not null,
  city text not null,
  area text not null,
  code text not null unique,
  status text not null default 'trial' check (status in ('trial','active','paused','locked')),
  trial_ends timestamptz not null default (now() + interval '30 days'),
  license_ends timestamptz,
  plan_type text check (plan_type in ('monthly','yearly')),
  plan_amount numeric check (plan_amount > 0),
  rc_next integer not null default 1001,
  created_at timestamptz not null default now()
);

create table public.apartments (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.buildings(id) on delete cascade,
  code text not null,
  floor integer not null,
  resident_id uuid references public.profiles(id),
  invited boolean not null default false,
  unique (building_id, code)
);

create table public.charges (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.buildings(id) on delete cascade,
  apartment_id uuid not null references public.apartments(id) on delete cascade,
  period text not null,
  amount numeric not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (apartment_id, period)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.buildings(id) on delete cascade,
  apartment_id uuid not null references public.apartments(id) on delete cascade,
  amount numeric not null check (amount > 0),
  receipt_no text not null,
  cancelled boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.buildings(id) on delete cascade,
  category text not null,
  amount numeric not null check (amount > 0),
  period text not null,
  note text not null default '',
  invoice_path text,
  deleted boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  building_id uuid references public.buildings(id) on delete cascade,
  kind text not null,
  detail jsonb not null default '{}'::jsonb,
  actor uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index on public.apartments (building_id);
create index on public.apartments (resident_id);
create index on public.charges (apartment_id);
create index on public.payments (apartment_id);
create index on public.expenses (building_id, period);
create index on public.audit_log (building_id, created_at desc);

-- ---------- create a profile for every new account ----------
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, mobile, email)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name',''),
          coalesce(new.raw_user_meta_data->>'mobile',''),
          coalesce(new.email,''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- who-is-who helpers ----------
create function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where user_id = auth.uid()) $$;

create function public.is_manager(b uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from buildings where id = b and manager_id = auth.uid()) $$;

create function public.is_member(b uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from apartments where building_id = b and resident_id = auth.uid()) $$;

-- license is usable: trial not over, or paid license not over (paused/locked = not usable)
create function public.lic_ok(b uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from buildings where id = b and (
    (status = 'trial' and trial_ends > now()) or (status = 'active' and license_ends > now()))) $$;

-- ---------- row level security: who may READ what ----------
alter table public.profiles   enable row level security;
alter table public.app_admins enable row level security;
alter table public.buildings  enable row level security;
alter table public.apartments enable row level security;
alter table public.charges    enable row level security;
alter table public.payments   enable row level security;
alter table public.expenses   enable row level security;
alter table public.audit_log  enable row level security;

create policy "own profile" on public.profiles for select
  using (id = auth.uid() or public.is_admin());
create policy "manager sees resident names" on public.profiles for select
  using (exists (select 1 from apartments a join buildings b on b.id = a.building_id
                 where a.resident_id = profiles.id and b.manager_id = auth.uid()));
create policy "buildings read" on public.buildings for select
  using (manager_id = auth.uid() or public.is_member(id) or public.is_admin());
create policy "owner updates buildings" on public.buildings for update
  using (public.is_admin()) with check (public.is_admin());
-- a resident sees ONLY their own apartment; the manager sees all
create policy "apartments read" on public.apartments for select
  using (public.is_manager(building_id) or resident_id = auth.uid() or public.is_admin());
create policy "charges read" on public.charges for select
  using (public.is_manager(building_id)
         or exists (select 1 from apartments a where a.id = apartment_id and a.resident_id = auth.uid()));
create policy "payments read" on public.payments for select
  using (public.is_manager(building_id)
         or exists (select 1 from apartments a where a.id = apartment_id and a.resident_id = auth.uid()));
-- every resident of the building sees the building expenses
create policy "expenses read" on public.expenses for select
  using (public.is_manager(building_id) or public.is_member(building_id));
-- change history: manager (and you) only
create policy "audit read" on public.audit_log for select
  using (public.is_manager(building_id) or public.is_admin());
create policy "admins read admins" on public.app_admins for select using (user_id = auth.uid());

-- no insert / update / delete policies exist for the app => direct writes are impossible

-- ---------- helper: write to the change history ----------
create function public.log_it(b uuid, k text, d jsonb) returns void
language sql security definer set search_path = public as $$
  insert into audit_log (building_id, kind, detail, actor) values (b, k, d, auth.uid()) $$;
revoke all on function public.log_it(uuid, text, jsonb) from public, anon, authenticated;

-- ---------- app actions (the ONLY way to change data) ----------
-- create a building (trial = 1 building, paid = up to 3). p_per = apartments on each floor, e.g. {2,2,2}
create function public.create_building(p_name text, p_gov text, p_city text, p_area text, p_per int[])
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); lim int; n_have int; c text; bid uuid; i int; k int;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_gov),'') = '' or coalesce(trim(p_city),'') = '' or coalesce(trim(p_area),'') = '' then
    raise exception 'missing building details'; end if;
  if p_per is null or array_length(p_per,1) is null or array_length(p_per,1) > 40 then raise exception 'bad floors'; end if;
  select count(*) into n_have from buildings where manager_id = uid;
  lim := case when exists (select 1 from buildings where manager_id = uid and status = 'active') then 3 else 1 end;
  if n_have >= lim then raise exception 'license limit reached'; end if;
  loop
    c := '';
    for i in 1..5 loop c := c || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random()*32)::int, 1); end loop;
    exit when not exists (select 1 from buildings where code = c);
  end loop;
  insert into buildings (manager_id, name, gov, city, area, code)
    values (uid, trim(p_name), trim(p_gov), trim(p_city), trim(p_area), c) returning id into bid;
  for i in 1..array_length(p_per,1) loop
    if p_per[i] < 1 or p_per[i] > 99 then raise exception 'bad apartment count'; end if;
    for k in 1..p_per[i] loop
      insert into apartments (building_id, code, floor) values (bid, (i*100+k)::text, i);
    end loop;
  end loop;
  perform log_it(bid, 'building', jsonb_build_object('name', p_name));
  return bid;
end $$;

-- resident joins with a code like NILE24-102
create function public.join_building(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); parts text[]; b uuid; a uuid; cur uuid;
begin
  if uid is null then raise exception 'not signed in'; end if;
  parts := string_to_array(upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g')), '-');
  select id into b from buildings where code = parts[1];
  if b is null then raise exception 'building not found'; end if;
  select id, resident_id into a, cur from apartments where building_id = b and code = parts[2];
  if a is null then raise exception 'apartment not found'; end if;
  if cur is not null and cur <> uid then raise exception 'apartment already linked'; end if;
  update apartments set resident_id = uid where id = a;
  perform log_it(b, 'join', jsonb_build_object('apartment', parts[2]));
  return b;
end $$;

create function public.mark_invited(p_apartment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  select building_id into b from apartments where id = p_apartment;
  if not is_manager(b) then raise exception 'not allowed'; end if;
  update apartments set invited = true where id = p_apartment;
end $$;

-- fee plan
create function public.set_plan(p_building uuid, p_type text, p_amount numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if p_type not in ('monthly','yearly') or p_amount is null or p_amount <= 0 then raise exception 'bad plan'; end if;
  update buildings set plan_type = p_type, plan_amount = p_amount where id = p_building;
  perform log_it(p_building, 'plan', jsonb_build_object('type', p_type, 'amount', p_amount));
end $$;

-- add the fee for a period (e.g. '2026-11' or '2026') to every apartment
create function public.add_fees(p_building uuid, p_period text) returns integer
language plpgsql security definer set search_path = public as $$
declare pl numeric; n integer;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  select plan_amount into pl from buildings where id = p_building;
  if pl is null then raise exception 'set the fee plan first'; end if;
  insert into charges (building_id, apartment_id, period, amount)
    select p_building, id, p_period, pl from apartments where building_id = p_building
    on conflict (apartment_id, period) do nothing;
  get diagnostics n = row_count;
  perform log_it(p_building, 'fees', jsonb_build_object('period', p_period, 'amount', pl, 'apartments', n));
  return n;
end $$;

-- what an apartment still owes
create function public.due_of(p_apartment uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((select sum(amount) from charges where apartment_id = p_apartment), 0)
  - coalesce((select sum(amount) from payments where apartment_id = p_apartment and not cancelled), 0), 0) $$;
revoke all on function public.due_of(uuid) from public, anon, authenticated;

-- record a payment (part payments fine; cannot exceed what is owed)
create function public.add_payment(p_apartment uuid, p_amount numeric) returns text
language plpgsql security definer set search_path = public as $$
declare b uuid; rc text; due numeric;
begin
  select building_id into b from apartments where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'bad amount'; end if;
  due := due_of(p_apartment);
  if p_amount > due then raise exception 'amount is more than the outstanding %', due; end if;
  update buildings set rc_next = rc_next + 1 where id = b returning 'R-' || (rc_next - 1) into rc;
  insert into payments (building_id, apartment_id, amount, receipt_no, created_by) values (b, p_apartment, p_amount, rc, auth.uid());
  perform log_it(b, 'pay', jsonb_build_object('apartment', p_apartment, 'amount', p_amount, 'receipt', rc));
  return rc;
end $$;

-- cancel the last payment of an apartment (kept in history, never erased)
create function public.cancel_last_payment(p_apartment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; pid uuid; amt numeric; rc text;
begin
  select building_id into b from apartments where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  select id, amount, receipt_no into pid, amt, rc from payments
    where apartment_id = p_apartment and not cancelled order by created_at desc limit 1;
  if pid is null then raise exception 'no payment to cancel'; end if;
  update payments set cancelled = true where id = pid;
  perform log_it(b, 'cancel', jsonb_build_object('apartment', p_apartment, 'amount', amt, 'receipt', rc));
end $$;

create function public.add_expense(p_building uuid, p_category text, p_amount numeric, p_period text, p_note text, p_invoice text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'bad amount'; end if;
  insert into expenses (building_id, category, amount, period, note, invoice_path, created_by)
    values (p_building, p_category, p_amount, p_period, coalesce(p_note,''), p_invoice, auth.uid()) returning expenses.id into id;
  perform log_it(p_building, 'exp', jsonb_build_object('category', p_category, 'amount', p_amount, 'period', p_period));
  return id;
end $$;

create function public.delete_expense(p_expense uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid; c text; a numeric;
begin
  select building_id, category, amount into b, c, a from expenses where id = p_expense and not deleted;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  update expenses set deleted = true where id = p_expense;
  perform log_it(b, 'delexp', jsonb_build_object('category', c, 'amount', a));
end $$;

-- money received per month: residents see totals only, never other people's payments
create function public.monthly_cash(p_building uuid) returns table (period text, total numeric)
language sql stable security definer set search_path = public as $$
  select to_char(created_at, 'YYYY-MM'), sum(amount) from payments
  where building_id = p_building and not cancelled and (is_manager(p_building) or is_member(p_building))
  group by 1 order by 1 $$;

-- ---------- invoice photos (private storage) ----------
insert into storage.buckets (id, name, public) values ('invoices', 'invoices', false) on conflict do nothing;

create policy "invoice upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'invoices'
    and public.is_manager(((storage.foldername(name))[1])::uuid)
    and public.lic_ok(((storage.foldername(name))[1])::uuid));
create policy "invoice view" on storage.objects for select to authenticated
  using (bucket_id = 'invoices'
    and (public.is_manager(((storage.foldername(name))[1])::uuid)
      or public.is_member(((storage.foldername(name))[1])::uuid)));

-- ---------- let signed-in users call the actions ----------
revoke execute on all functions in schema public from public, anon;
grant execute on function public.create_building(text,text,text,text,int[]) to authenticated;
grant execute on function public.join_building(text) to authenticated;
grant execute on function public.mark_invited(uuid) to authenticated;
grant execute on function public.set_plan(uuid,text,numeric) to authenticated;
grant execute on function public.add_fees(uuid,text) to authenticated;
grant execute on function public.add_payment(uuid,numeric) to authenticated;
grant execute on function public.cancel_last_payment(uuid) to authenticated;
grant execute on function public.add_expense(uuid,text,numeric,text,text,text) to authenticated;
grant execute on function public.delete_expense(uuid) to authenticated;
grant execute on function public.monthly_cash(uuid) to authenticated;
grant execute on function public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid) to authenticated;
