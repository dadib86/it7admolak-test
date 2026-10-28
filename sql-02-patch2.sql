-- Patch 2: preferences, one-time tour, mandatory authenticator for managers,
-- no manager via join code, owner reset of a manager's authenticator.
-- Run once in Supabase > SQL Editor (after patch 1).

-- 1) profile settings: language, theme, tour shown once
alter table public.profiles
  add column if not exists lang text not null default 'ar' check (lang in ('ar','en')),
  add column if not exists theme text not null default 'system' check (theme in ('system','light','dark')),
  add column if not exists tour_manager boolean not null default false,
  add column if not exists tour_resident boolean not null default false;

create or replace function public.set_prefs(p_lang text, p_theme text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_lang not in ('ar','en') or p_theme not in ('system','light','dark') then raise exception 'bad value'; end if;
  update profiles set lang = p_lang, theme = p_theme where id = auth.uid();
end $$;

create or replace function public.set_tour(p_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_role = 'manager' then update profiles set tour_manager = true where id = auth.uid();
  elsif p_role = 'resident' then update profiles set tour_resident = true where id = auth.uid();
  else raise exception 'bad role'; end if;
end $$;

-- 2) a manager acts only after the authenticator-app step (aal2).
--    Turning the authenticator off locks the manager out until the owner resets it.
create or replace function public.is_manager(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.jwt()->>'aal','') = 'aal2'
     and exists (select 1 from buildings where id = b and manager_id = auth.uid()) $$;

-- 3) nobody becomes a manager by joining, and a resident cannot create a building
create or replace function public.create_building(p_name text, p_gov text, p_city text, p_area text, p_per int[])
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); lim int; n_have int; c text; bid uuid; i int; k int;
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

create or replace function public.join_building(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); parts text[]; b uuid; a uuid; cur uuid;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from buildings where manager_id = uid) then raise exception 'managers cannot join as residents'; end if;
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

-- 4) OWNER ONLY: reset a manager's authenticator (they set up a new one at next sign-in).
--    Use in the SQL Editor:   select public.admin_reset_mfa('manager@email.com');
create or replace function public.admin_reset_mfa(p_email text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare u uuid;
begin
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then return 'no such user'; end if;
  delete from auth.mfa_factors where user_id = u;
  delete from auth.sessions where user_id = u;
  return 'authenticator reset; user must sign in again';
end $$;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;

revoke execute on function public.set_prefs(text,text), public.set_tour(text) from public, anon;
grant execute on function public.set_prefs(text,text), public.set_tour(text) to authenticated;

-- 5) make yourself the owner (do this AFTER you have signed in to the app once with your email):
--    insert into public.app_admins (user_id) select id from auth.users where lower(email) = lower('YOUR-EMAIL-HERE');
