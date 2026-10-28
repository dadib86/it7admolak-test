-- Patch 10 (REVISED, safe to run even if you ran the first version): hand a building over to another manager.
--  * the current manager chooses his own apartment; after the transfer he becomes a resident of that apartment.
--  * the manager enters the new manager's email; the new manager accepts (or declines) inside the app.
--  * the owner (you) can also move a building directly from the Owner dashboard (for example if the old manager is unreachable).
-- Run once in Supabase > SQL Editor (after patch 9). Run supabase-backup.sql first.

create table if not exists public.building_transfers (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.buildings(id) on delete cascade,
  from_user uuid not null references public.profiles(id),
  to_email text not null,
  building_name text not null default '',
  from_name text not null default '',
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.building_transfers add column if not exists from_apt text not null default '';
alter table public.building_transfers enable row level security;
drop policy if exists "transfers read" on public.building_transfers;
create policy "transfers read" on public.building_transfers for select
  using (from_user = auth.uid() or to_email = lower(coalesce(auth.jwt()->>'email','')));

-- can this person manage one more building?
create or replace function public.can_take_building(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from apartments where resident_id = p_user)
     and (select count(*) from buildings where manager_id = p_user and deleted_at is null)
         < case when exists (select 1 from buildings where manager_id = p_user and status = 'active' and deleted_at is null) then 3 else 1 end $$;
revoke all on function public.can_take_building(uuid) from public, anon, authenticated;

-- manager: offer the building to another person (they must already have an account)
-- p_apt = the apartment code the current manager will live in (he becomes its resident when the transfer is accepted)
drop function if exists public.request_transfer(uuid, text);
create or replace function public.request_transfer(p_building uuid, p_email text, p_apt text) returns uuid
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email,''))); tu uuid; bn text; fn text; nid uuid; ac text := upper(trim(coalesce(p_apt,''))); cur uuid; ex boolean;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad email'; end if;
  select pr.id into tu from profiles pr where lower(pr.email) = e;
  if tu is null then raise exception 'user not found'; end if;
  if tu = auth.uid() then raise exception 'cannot transfer to yourself'; end if;
  if exists (select 1 from apartments where resident_id = tu) then raise exception 'target is resident'; end if;
  if exists (select 1 from buildings where manager_id = auth.uid() and id <> p_building and deleted_at is null) then
    raise exception 'manager has other buildings'; end if;
  select true, resident_id into ex, cur from apartments where building_id = p_building and upper(code) = ac;
  if ex is not true then raise exception 'apartment not found'; end if;
  if cur is not null then raise exception 'apartment already linked'; end if;
  select name into bn from buildings where id = p_building;
  select name into fn from profiles where id = auth.uid();
  update building_transfers set status = 'cancelled', updated_at = now() where building_id = p_building and status = 'pending';
  insert into building_transfers (building_id, from_user, to_email, building_name, from_name, from_apt)
    values (p_building, auth.uid(), e, bn, coalesce(fn,''), ac) returning building_transfers.id into nid;
  insert into notifications (user_id, building_id, kind, data) values (tu, p_building, 'transfer', jsonb_build_object('building', bn, 'from', coalesce(fn,''), 'apt', ac));
  perform log_it(p_building, 'xfer_req', jsonb_build_object('to', e, 'apartment', ac));
  return nid;
end $$;

create or replace function public.cancel_transfer(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update building_transfers set status = 'cancelled', updated_at = now()
   where id = p_id and from_user = auth.uid() and status = 'pending';
  if not found then raise exception 'transfer not found'; end if;
end $$;

-- the new manager accepts or declines
create or replace function public.answer_transfer(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t building_transfers%rowtype; me text; tn text;
begin
  select lower(coalesce(auth.jwt()->>'email','')) into me;
  select * into t from building_transfers where id = p_id and status = 'pending' and to_email = me and created_at > now() - interval '14 days';
  if t.id is null then raise exception 'transfer not found'; end if;
  if not p_accept then
    update building_transfers set status = 'declined', updated_at = now() where id = p_id;
    insert into notifications (user_id, building_id, kind, data) values (t.from_user, t.building_id, 'xferno', jsonb_build_object('building', t.building_name));
    return;
  end if;
  if coalesce(auth.jwt()->>'aal','') <> 'aal2' then raise exception 'authenticator required'; end if;
  if not exists (select 1 from buildings where id = t.building_id and manager_id = t.from_user and deleted_at is null) then raise exception 'transfer not found'; end if;
  if not can_take_building(auth.uid()) then raise exception 'target license limit reached'; end if;
  select name into tn from profiles where id = auth.uid();
  -- the old manager becomes the resident of the apartment he chose
  if t.from_apt <> '' then
    if not exists (select 1 from apartments where building_id = t.building_id and upper(code) = t.from_apt and resident_id is null) then
      raise exception 'apartment already linked'; end if;
    if exists (select 1 from buildings where manager_id = t.from_user and id <> t.building_id and deleted_at is null) then
      raise exception 'manager has other buildings'; end if;
  end if;
  update buildings set manager_id = auth.uid() where id = t.building_id;
  if t.from_apt <> '' then
    update apartments set resident_id = t.from_user, invited = true where building_id = t.building_id and upper(code) = t.from_apt;
  end if;
  update building_transfers set status = 'accepted', updated_at = now() where id = p_id;
  perform log_it(t.building_id, 'xfer', jsonb_build_object('from', t.from_name, 'to', coalesce(tn,''), 'apartment', t.from_apt));
  insert into notifications (user_id, building_id, kind, data) values (t.from_user, t.building_id, 'xferdone', jsonb_build_object('building', t.building_name, 'name', coalesce(tn,''), 'apt', t.from_apt));
end $$;

-- owner: move a building directly
create or replace function public.admin_transfer_building(p_building uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email,''))); tu uuid; old uuid; bn text; fn text; tn text;
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  select pr.id, pr.name into tu, tn from profiles pr where lower(pr.email) = e;
  if tu is null then raise exception 'user not found'; end if;
  if exists (select 1 from apartments where resident_id = tu) then raise exception 'target is resident'; end if;
  select manager_id, name into old, bn from buildings where id = p_building;
  if old is null then raise exception 'not allowed'; end if;
  if old = tu then raise exception 'cannot transfer to yourself'; end if;
  select name into fn from profiles where id = old;
  update buildings set manager_id = tu where id = p_building;
  update building_transfers set status = 'cancelled', updated_at = now() where building_id = p_building and status = 'pending';
  perform log_it(p_building, 'xfer', jsonb_build_object('from', coalesce(fn,''), 'to', coalesce(tn,'')));
  insert into notifications (user_id, building_id, kind, data) values
    (tu, p_building, 'xferyou', jsonb_build_object('building', bn)),
    (old, p_building, 'xferout', jsonb_build_object('building', bn));
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.request_transfer(uuid,text,text), public.cancel_transfer(uuid), public.answer_transfer(uuid,boolean),
  public.admin_transfer_building(uuid,text) to authenticated;
-- keep earlier grants working
grant execute on function public.update_building(uuid,text,text,text,text,int[]), public.delete_building(uuid,text),
  public.add_expense(uuid,text,numeric,text,text,text), public.delete_expense(uuid), public.set_plan(uuid,text,numeric),
  public.create_building(text,text,text,text,int[]), public.join_building(text), public.mark_invited(uuid),
  public.cancel_last_payment(uuid), public.monthly_cash(uuid), public.set_profile(text,text),
  public.set_prefs(text,text), public.set_tour(text), public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid),
  public.submit_request(text,text), public.admin_requests(), public.admin_set_request(uuid,text,text), public.admin_set_building(uuid,text,timestamptz,text),
  public.admin_reset_manager(text), public.mark_notifs_read(), public.notify_building(uuid,uuid,text), public.owner_notify(text,text),
  public.admin_buildings(), public.admin_restore_building(uuid), public.admin_purge_building(uuid),
  public.add_payment(uuid,numeric,text), public.add_fees(uuid,text), public.remove_fees(uuid,text), public.cancel_payment(uuid) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
