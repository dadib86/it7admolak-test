-- Patch 6: safe delete. A deleted building is hidden and kept; only you (owner) can restore it or erase it for good.
-- Run once in Supabase > SQL Editor (after patch 5). Run supabase-backup.sql first.

alter table public.buildings add column if not exists deleted_at timestamptz;

-- deleted buildings disappear for managers and residents
drop policy if exists "buildings read" on public.buildings;
create policy "buildings read" on public.buildings for select
  using ((deleted_at is null and (manager_id = auth.uid() or public.is_member(id))) or public.is_admin());

create or replace function public.is_manager(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.jwt()->>'aal','') = 'aal2'
     and exists (select 1 from buildings where id = b and manager_id = auth.uid() and deleted_at is null) $$;

create or replace function public.is_member(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from apartments a join buildings bb on bb.id = a.building_id
                 where a.building_id = b and a.resident_id = auth.uid() and bb.deleted_at is null) $$;

create or replace function public.lic_ok(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from buildings where id = b and deleted_at is null and (
    (status = 'trial' and trial_ends > now()) or (status = 'active' and license_ends > now()))) $$;

-- a manager can create a new building after deleting one, but the 30-day trial still belongs to the person
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
  select count(*) into n_have from buildings where manager_id = uid and deleted_at is null;
  lim := case when exists (select 1 from buildings where manager_id = uid and status = 'active' and deleted_at is null) then 3 else 1 end;
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

create or replace function public.join_building(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); parts text[]; b uuid; a uuid; cur uuid;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from buildings where manager_id = uid and deleted_at is null) then raise exception 'managers cannot join as residents'; end if;
  parts := string_to_array(upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g')), '-');
  select id into b from buildings where code = parts[1] and deleted_at is null;
  if b is null then raise exception 'building not found'; end if;
  select id, resident_id into a, cur from apartments where building_id = b and code = parts[2];
  if a is null then raise exception 'apartment not found'; end if;
  if cur is not null and cur <> uid then raise exception 'apartment already linked'; end if;
  update apartments set resident_id = uid where id = a;
  perform log_it(b, 'join', jsonb_build_object('apartment', parts[2]));
  return b;
end $$;

-- manager "delete" = hide (trial buildings only, name must match). Nothing is erased.
create or replace function public.delete_building(p_building uuid, p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare b buildings%rowtype;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  select * into b from buildings where id = p_building;
  if b.status <> 'trial' then raise exception 'paid building cannot be deleted'; end if;
  if trim(coalesce(p_confirm,'')) <> b.name then raise exception 'name does not match'; end if;
  perform log_it(p_building, 'deleted', jsonb_build_object('name', b.name));
  update buildings set deleted_at = now() where id = p_building;
end $$;

-- owner: list (now with deleted_at), restore, erase for good
drop function if exists public.admin_buildings();
create function public.admin_buildings() returns table
 (id uuid, name text, code text, gov text, city text, status text, trial_ends timestamptz, license_ends timestamptz,
  admin_note text, created_at timestamptz, manager_name text, manager_email text, manager_mobile text, apts bigint, joined bigint,
  deleted_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select b.id, b.name, b.code, b.gov, b.city, b.status, b.trial_ends, b.license_ends, b.admin_note, b.created_at,
      p.name, p.email, p.mobile,
      (select count(*) from apartments a where a.building_id = b.id),
      (select count(*) from apartments a where a.building_id = b.id and a.resident_id is not null),
      b.deleted_at
    from buildings b join profiles p on p.id = b.manager_id order by (b.deleted_at is not null), b.created_at desc;
end $$;

create or replace function public.admin_restore_building(p_building uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m uuid; n text;
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update buildings set deleted_at = null where id = p_building and deleted_at is not null returning manager_id, name into m, n;
  if m is null then raise exception 'not deleted'; end if;
  perform log_it(p_building, 'restored', jsonb_build_object('name', n));
  insert into notifications (user_id, building_id, kind, data) values (m, p_building, 'restored', jsonb_build_object('building', n));
end $$;

create or replace function public.admin_purge_building(p_building uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if not exists (select 1 from buildings where id = p_building and deleted_at is not null) then raise exception 'not deleted'; end if;
  delete from buildings where id = p_building;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.admin_buildings(), public.admin_restore_building(uuid), public.admin_purge_building(uuid),
  public.delete_building(uuid,text), public.create_building(text,text,text,text,int[]), public.join_building(text),
  public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid) to authenticated;
-- keep earlier grants working
grant execute on function public.update_building(uuid,text,text,text,text,int[]), public.cancel_payment(uuid),
  public.remove_fees(uuid,text), public.add_expense(uuid,text,numeric,text,text,text), public.delete_expense(uuid), public.set_plan(uuid,text,numeric),
  public.mark_invited(uuid), public.add_fees(uuid,text), public.add_payment(uuid,numeric), public.cancel_last_payment(uuid), public.monthly_cash(uuid),
  public.set_profile(text,text), public.set_prefs(text,text), public.set_tour(text), public.is_admin(),
  public.submit_request(text,text), public.admin_requests(), public.admin_set_request(uuid,text,text), public.admin_set_building(uuid,text,timestamptz,text),
  public.admin_reset_manager(text), public.mark_notifs_read(), public.notify_building(uuid,uuid,text), public.owner_notify(text,text) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
