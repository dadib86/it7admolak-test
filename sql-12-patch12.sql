-- Patch 12: the resident also gets an instant notification when the manager marks a fee as settled or the apartment as exempt.
-- Run once in Supabase > SQL Editor (after patch 11). Safe to run twice.
create or replace function public.trg_notify_settled() returns trigger
language plpgsql security definer set search_path = public as $$
declare r uuid; bname text;
begin
  if new.settled and not old.settled and not new.settled_auto then
    select a.resident_id, b.name into r, bname from apartments a join buildings b on b.id = a.building_id where a.id = new.apartment_id;
    if r is not null then
      insert into notifications (user_id, building_id, kind, data)
        values (r, new.building_id, 'settled', jsonb_build_object('period', new.period, 'building', bname));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists notify_settled on public.charges;
create trigger notify_settled after update on public.charges for each row execute function public.trg_notify_settled();

create or replace function public.trg_notify_exempt() returns trigger
language plpgsql security definer set search_path = public as $$
declare bname text;
begin
  if new.exempt and not old.exempt and new.resident_id is not null then
    select name into bname from buildings where id = new.building_id;
    insert into notifications (user_id, building_id, kind, data)
      values (new.resident_id, new.building_id, 'exempt', jsonb_build_object('building', bname));
  end if;
  return new;
end $$;
drop trigger if exists notify_exempt on public.apartments;
create trigger notify_exempt after update on public.apartments for each row execute function public.trg_notify_exempt();

revoke all on function public.trg_notify_settled(), public.trg_notify_exempt() from public, anon, authenticated;
