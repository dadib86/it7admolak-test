-- Patch 16: custom tags for apartments (for example Shop, Closed, Owner abroad).
-- The manager creates tags, then gives one tag to any apartment. Tags are only labels (they do not change fees).
-- Run once in Supabase > SQL Editor (after patch 15). Safe to run twice.

create table if not exists public.apartment_tags (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.buildings(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 30),
  created_at timestamptz not null default now()
);
create unique index if not exists apartment_tags_name_uq on public.apartment_tags (building_id, lower(name));
alter table public.apartment_tags enable row level security;
drop policy if exists "tags read" on public.apartment_tags;
create policy "tags read" on public.apartment_tags for select using (public.is_manager(building_id));

alter table public.apartments add column if not exists tag_id uuid references public.apartment_tags(id) on delete set null;

create or replace function public.add_tag(p_building uuid, p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare nm text := left(trim(coalesce(p_name,'')), 30); nid uuid;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if nm = '' then raise exception 'bad name'; end if;
  if (select count(*) from apartment_tags where building_id = p_building) >= 20 then raise exception 'too many tags'; end if;
  if exists (select 1 from apartment_tags where building_id = p_building and lower(name) = lower(nm)) then raise exception 'tag exists'; end if;
  insert into apartment_tags (building_id, name) values (p_building, nm) returning id into nid;
  return nid;
end $$;

create or replace function public.delete_tag(p_tag uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  select building_id into b from apartment_tags where id = p_tag;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  delete from apartment_tags where id = p_tag;
end $$;

create or replace function public.set_apt_tag(p_apartment uuid, p_tag uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  select building_id into b from apartments where id = p_apartment;
  if b is null or not is_manager(b) then raise exception 'not allowed'; end if;
  if not lic_ok(b) then raise exception 'license locked'; end if;
  if p_tag is not null and not exists (select 1 from apartment_tags where id = p_tag and building_id = b) then raise exception 'not allowed'; end if;
  update apartments set tag_id = p_tag where id = p_apartment;
end $$;

grant execute on function public.add_tag(uuid,text), public.delete_tag(uuid), public.set_apt_tag(uuid,uuid) to authenticated;
