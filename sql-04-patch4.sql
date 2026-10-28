-- Patch 4: support requests (enquiry / complaint / feature / other) + owner dashboard.
-- Run once in Supabase > SQL Editor (after patch 3).
-- Then make yourself the owner (after you have signed in to the app once):
--   insert into public.app_admins (user_id) select id from auth.users where lower(email)=lower('YOUR-EMAIL-HERE');

-- owner powers need the authenticator step (aal2), like managers
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(auth.jwt()->>'aal','') = 'aal2' and exists (select 1 from app_admins where user_id = auth.uid()) $$;

alter table public.buildings add column if not exists admin_note text not null default '';

-- ---------- support requests ----------
create table if not exists public.requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('question','complaint','feature','other')),
  message text not null check (char_length(message) between 5 and 2000),
  status text not null default 'new' check (status in ('new','seen','done')),
  reply text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.requests enable row level security;
drop policy if exists "requests read own" on public.requests;
create policy "requests read own" on public.requests for select using (user_id = auth.uid());

create or replace function public.submit_request(p_kind text, p_message text) returns uuid
language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_kind not in ('question','complaint','feature','other') then raise exception 'bad kind'; end if;
  if char_length(trim(coalesce(p_message,''))) < 5 then raise exception 'message too short'; end if;
  if (select count(*) from requests where user_id = auth.uid() and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too many requests'; end if;
  insert into requests (user_id, kind, message) values (auth.uid(), p_kind, left(trim(p_message), 2000)) returning requests.id into id;
  return id;
end $$;

-- ---------- owner only ----------
create or replace function public.admin_requests() returns table
 (id uuid, kind text, message text, status text, reply text, created_at timestamptz, name text, email text, mobile text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select r.id, r.kind, r.message, r.status, r.reply, r.created_at, p.name, p.email, p.mobile
    from requests r join profiles p on p.id = r.user_id
    order by (r.status = 'done'), r.created_at desc limit 300;
end $$;

create or replace function public.admin_set_request(p_id uuid, p_status text, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('new','seen','done') then raise exception 'bad status'; end if;
  update requests set status = p_status, reply = left(coalesce(trim(p_reply),''), 2000), updated_at = now() where id = p_id;
end $$;

create or replace function public.admin_buildings() returns table
 (id uuid, name text, code text, gov text, city text, status text, trial_ends timestamptz, license_ends timestamptz,
  admin_note text, created_at timestamptz, manager_name text, manager_email text, manager_mobile text, apts bigint, joined bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select b.id, b.name, b.code, b.gov, b.city, b.status, b.trial_ends, b.license_ends, b.admin_note, b.created_at,
      p.name, p.email, p.mobile,
      (select count(*) from apartments a where a.building_id = b.id),
      (select count(*) from apartments a where a.building_id = b.id and a.resident_id is not null)
    from buildings b join profiles p on p.id = b.manager_id order by b.created_at desc;
end $$;

-- change a building's subscription: status trial/active/paused/locked, with the end date for trial or active
create or replace function public.admin_set_building(p_building uuid, p_status text, p_ends timestamptz, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('trial','active','paused','locked') then raise exception 'bad status'; end if;
  if p_status = 'active' and (p_ends is null) then raise exception 'end date required'; end if;
  update buildings set status = p_status,
      license_ends = case when p_status = 'active' then p_ends else license_ends end,
      trial_ends = case when p_status = 'trial' and p_ends is not null then p_ends else trial_ends end,
      admin_note = left(coalesce(p_note, admin_note), 500)
    where id = p_building;
  perform log_it(p_building, 'license', jsonb_build_object('status', p_status, 'ends', p_ends));
end $$;

-- reset a manager's authenticator from the app (the manager sets up a new one at next sign-in)
create or replace function public.admin_reset_manager(p_email text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if lower(trim(p_email)) = (select lower(email) from auth.users where id = auth.uid()) then raise exception 'cannot reset yourself'; end if;
  return admin_reset_mfa(p_email);
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.submit_request(text,text), public.admin_requests(), public.admin_set_request(uuid,text,text),
  public.admin_buildings(), public.admin_set_building(uuid,text,timestamptz,text), public.admin_reset_manager(text) to authenticated;
-- keep earlier grants working
grant execute on function public.update_building(uuid,text,text,text,text,int[]), public.delete_building(uuid,text), public.cancel_payment(uuid),
  public.remove_fees(uuid,text), public.add_expense(uuid,text,numeric,text,text,text), public.delete_expense(uuid), public.set_plan(uuid,text,numeric),
  public.create_building(text,text,text,text,int[]), public.join_building(text), public.mark_invited(uuid), public.add_fees(uuid,text),
  public.add_payment(uuid,numeric), public.cancel_last_payment(uuid), public.monthly_cash(uuid), public.set_profile(text,text),
  public.set_prefs(text,text), public.set_tour(text), public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
