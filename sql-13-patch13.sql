-- Patch 13: managers sign in with the email code only (no authenticator app).
--  * the authenticator step is no longer needed to manage a building, create a building or accept a transfer.
--  * the owner dashboard still asks for the authenticator code (it can see every building).
-- Run once in Supabase > SQL Editor (after patch 12). Safe to run twice.

create or replace function public.is_manager(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from buildings where id = b and manager_id = auth.uid() and deleted_at is null) $$;

create or replace function public.create_building(p_name text, p_gov text, p_city text, p_area text, p_per int[])
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); lim int; n_have int; c text; bid uuid; i int; k int; ts timestamptz;
begin
  if uid is null then raise exception 'not signed in'; end if;
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

-- (permissions stay as they were)
