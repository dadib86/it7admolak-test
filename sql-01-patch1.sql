-- Patch 1: let a signed-in user save their own name and mobile
create function public.set_profile(p_name text, p_mobile text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'name required'; end if;
  if p_mobile !~ '^01[0125][0-9]{8}$' then raise exception 'bad mobile'; end if;
  update profiles set name = trim(p_name), mobile = p_mobile where id = auth.uid();
end $$;
revoke execute on function public.set_profile(text,text) from public, anon;
grant execute on function public.set_profile(text,text) to authenticated;
