-- Patch 17: ground floor. A building can have ground-floor apartments named G1, G2, ... (shown as "Ground"), then floor 1, floor 2, ...
-- The ground floor is chosen when creating a building, or in Edit building (only while nobody has joined and no fees exist, like the other floors).
-- Run once in Supabase > SQL Editor (after patch 16). Safe to run twice.

drop function if exists public.create_building(text,text,text,text,int[]);
drop function if exists public.update_building(uuid,text,text,text,text,int[]);

create or replace function public.create_building(p_name text, p_gov text, p_city text, p_area text, p_per int[], p_ground int default 0)
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
  if p_ground is null or p_ground < 0 or p_ground > 99 then raise exception 'bad apartment count'; end if;
  for k in 1..p_ground loop
    insert into apartments (building_id, code, floor) values (bid, 'G' || k, 0);
  end loop;
  for i in 1..array_length(p_per,1) loop
    if p_per[i] < 1 or p_per[i] > 99 then raise exception 'bad apartment count'; end if;
    for k in 1..p_per[i] loop
      insert into apartments (building_id, code, floor) values (bid, (i*100+k)::text, i);
    end loop;
  end loop;
  perform log_it(bid, 'building', jsonb_build_object('name', p_name));
  return bid;
end $$;

create or replace function public.update_building(p_building uuid, p_name text, p_gov text, p_city text, p_area text, p_per int[], p_ground int default null)
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
    if coalesce(p_ground,0) < 0 or coalesce(p_ground,0) > 99 then raise exception 'bad apartment count'; end if;
    delete from apartments where building_id = p_building;
    for k in 1..coalesce(p_ground,0) loop
      insert into apartments (building_id, code, floor) values (p_building, 'G' || k, 0);
    end loop;
    for i in 1..array_length(p_per,1) loop
      if p_per[i] < 1 or p_per[i] > 99 then raise exception 'bad apartment count'; end if;
      for k in 1..p_per[i] loop
        insert into apartments (building_id, code, floor) values (p_building, (i*100+k)::text, i);
      end loop;
    end loop;
  end if;
  perform log_it(p_building, 'edit', jsonb_build_object('name', trim(p_name)));
end $$;

revoke all on function public.create_building(text,text,text,text,int[],int), public.update_building(uuid,text,text,text,text,int[],int) from public, anon;
grant execute on function public.create_building(text,text,text,text,int[],int), public.update_building(uuid,text,text,text,text,int[],int) to authenticated;
