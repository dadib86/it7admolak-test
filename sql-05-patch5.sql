-- Patch 5: in-app notifications (bell icon).
--  * owner -> all managers (or everyone)
--  * manager -> all residents of the building, or one apartment
--  * automatic: payment received / cancelled, new fees, reply to a support request, subscription changes
-- Run once in Supabase > SQL Editor (after patch 4).

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  building_id uuid references public.buildings(id) on delete cascade,
  kind text not null,
  message text not null default '',
  data jsonb not null default '{}'::jsonb,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
drop policy if exists "notifications read own" on public.notifications;
create policy "notifications read own" on public.notifications for select using (user_id = auth.uid());

-- mark all my notifications as read
create or replace function public.mark_notifs_read() returns void
language sql security definer set search_path = public as $$
  update notifications set read = true where user_id = auth.uid() and not read $$;

-- manager -> residents. p_apartment null = every resident of the building
create or replace function public.notify_building(p_building uuid, p_apartment uuid, p_message text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer; bname text; acode text;
begin
  if not is_manager(p_building) then raise exception 'not allowed'; end if;
  if not lic_ok(p_building) then raise exception 'license locked'; end if;
  if char_length(trim(coalesce(p_message,''))) < 3 then raise exception 'message too short'; end if;
  if (select count(*) from notifications where building_id = p_building and kind = 'announce' and created_at > now() - interval '1 day') > 200 then
    raise exception 'too many requests'; end if;
  select name into bname from buildings where id = p_building;
  if p_apartment is not null then select code into acode from apartments where id = p_apartment and building_id = p_building; end if;
  insert into notifications (user_id, building_id, kind, message, data)
    select a.resident_id, p_building, 'announce', left(trim(p_message), 500),
           jsonb_build_object('from', 'manager', 'building', bname, 'apt', coalesce(acode, ''))
    from apartments a
    where a.building_id = p_building and a.resident_id is not null and (p_apartment is null or a.id = p_apartment);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'no residents'; end if;
  return n;
end $$;

-- owner -> all managers ('managers') or everybody ('all')
create or replace function public.owner_notify(p_target text, p_message text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_target not in ('managers','all') then raise exception 'bad target'; end if;
  if char_length(trim(coalesce(p_message,''))) < 3 then raise exception 'message too short'; end if;
  insert into notifications (user_id, kind, message, data)
    select p.id, 'announce', left(trim(p_message), 500), jsonb_build_object('from', 'owner')
    from profiles p
    where p_target = 'all' or exists (select 1 from buildings b where b.manager_id = p.id);
  get diagnostics n = row_count;
  return n;
end $$;

-- automatic: payment received / cancelled -> the resident of that apartment
create or replace function public.trg_notify_payment() returns trigger
language plpgsql security definer set search_path = public as $$
declare r uuid; bname text;
begin
  select a.resident_id, b.name into r, bname from apartments a join buildings b on b.id = a.building_id where a.id = new.apartment_id;
  if r is null then return new; end if;
  if tg_op = 'INSERT' then
    insert into notifications (user_id, building_id, kind, data)
      values (r, new.building_id, 'payment', jsonb_build_object('amount', new.amount, 'receipt', new.receipt_no, 'building', bname));
  elsif new.cancelled and not old.cancelled then
    insert into notifications (user_id, building_id, kind, data)
      values (r, new.building_id, 'paycancel', jsonb_build_object('amount', new.amount, 'receipt', new.receipt_no, 'building', bname));
  end if;
  return new;
end $$;
drop trigger if exists notify_payment on public.payments;
create trigger notify_payment after insert or update on public.payments for each row execute function public.trg_notify_payment();

-- automatic: new fees -> the resident of that apartment
create or replace function public.trg_notify_charge() returns trigger
language plpgsql security definer set search_path = public as $$
declare r uuid; bname text;
begin
  select a.resident_id, b.name into r, bname from apartments a join buildings b on b.id = a.building_id where a.id = new.apartment_id;
  if r is null then return new; end if;
  insert into notifications (user_id, building_id, kind, data)
    values (r, new.building_id, 'fee', jsonb_build_object('amount', new.amount, 'period', new.period, 'building', bname));
  return new;
end $$;
drop trigger if exists notify_charge on public.charges;
create trigger notify_charge after insert on public.charges for each row execute function public.trg_notify_charge();

-- automatic: support reply and subscription changes (these replace the patch 4 versions)
create or replace function public.admin_set_request(p_id uuid, p_status text, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid; old_reply text; new_reply text := left(coalesce(trim(p_reply),''), 2000);
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('new','seen','done') then raise exception 'bad status'; end if;
  select user_id, reply into u, old_reply from requests where id = p_id;
  update requests set status = p_status, reply = new_reply, updated_at = now() where id = p_id;
  if u is not null and new_reply <> '' and new_reply <> coalesce(old_reply,'') then
    insert into notifications (user_id, kind, data) values (u, 'reply', '{}'::jsonb);
  end if;
end $$;

create or replace function public.admin_set_building(p_building uuid, p_status text, p_ends timestamptz, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare m uuid; old_status text;
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('trial','active','paused','locked') then raise exception 'bad status'; end if;
  if p_status = 'active' and (p_ends is null) then raise exception 'end date required'; end if;
  select manager_id, status into m, old_status from buildings where id = p_building;
  update buildings set status = p_status,
      license_ends = case when p_status = 'active' then p_ends else license_ends end,
      trial_ends = case when p_status = 'trial' and p_ends is not null then p_ends else trial_ends end,
      admin_note = left(coalesce(p_note, admin_note), 500)
    where id = p_building;
  perform log_it(p_building, 'license', jsonb_build_object('status', p_status, 'ends', p_ends));
  if m is not null and (p_status <> old_status or p_ends is not null) then
    insert into notifications (user_id, building_id, kind, data)
      values (m, p_building, 'license', jsonb_build_object('status', p_status, 'ends', p_ends, 'building', (select name from buildings where id = p_building)));
  end if;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.mark_notifs_read(), public.notify_building(uuid,uuid,text), public.owner_notify(text,text),
  public.admin_set_request(uuid,text,text), public.admin_set_building(uuid,text,timestamptz,text) to authenticated;
-- keep earlier grants working
grant execute on function public.submit_request(text,text), public.admin_requests(), public.admin_buildings(), public.admin_reset_manager(text),
  public.update_building(uuid,text,text,text,text,int[]), public.delete_building(uuid,text), public.cancel_payment(uuid),
  public.remove_fees(uuid,text), public.add_expense(uuid,text,numeric,text,text,text), public.delete_expense(uuid), public.set_plan(uuid,text,numeric),
  public.create_building(text,text,text,text,int[]), public.join_building(text), public.mark_invited(uuid), public.add_fees(uuid,text),
  public.add_payment(uuid,numeric), public.cancel_last_payment(uuid), public.monthly_cash(uuid), public.set_profile(text,text),
  public.set_prefs(text,text), public.set_tour(text), public.is_admin(), public.is_manager(uuid), public.is_member(uuid), public.lic_ok(uuid) to authenticated;
revoke execute on function public.admin_reset_mfa(text) from public, anon, authenticated;
