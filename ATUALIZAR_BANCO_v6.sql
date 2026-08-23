-- CORREÇÃO necessária para a versão compartilhada v6
-- Cole no Editor SQL do Supabase e clique em Correr.

drop policy if exists h_select on households;
drop policy if exists m_insert on household_members;

create policy h_select on households for select to authenticated
using (owner_id = auth.uid() or is_member(id));

create or replace function create_household(p_name text, p_invite_code text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare h households;
begin
  insert into households(name,invite_code,owner_id)
  values (p_name,upper(p_invite_code),auth.uid()) returning * into h;
  insert into household_members(household_id,user_id) values(h.id,auth.uid());
  return h;
end $$;

create or replace function join_household(p_invite_code text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare h households;
begin
  select * into h from households where invite_code=upper(trim(p_invite_code));
  if h.id is null then raise exception 'Código de convite inválido'; end if;
  insert into household_members(household_id,user_id)
  values(h.id,auth.uid()) on conflict do nothing;
  return h;
end $$;

revoke all on function create_household(text,text) from public;
revoke all on function join_household(text) from public;
grant execute on function create_household(text,text) to authenticated;
grant execute on function join_household(text) to authenticated;
