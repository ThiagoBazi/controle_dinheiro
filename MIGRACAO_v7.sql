-- MEU DINHEIRO v7
-- Rode este script UMA VEZ no Editor SQL do Supabase antes de publicar a v7.
-- Ele preserva as tabelas e lançamentos existentes.

create or replace function public.is_member(hid uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
 select exists(
   select 1 from public.household_members
   where household_id=hid and user_id=auth.uid()
 );
$$;

alter table public.household_members
  add column if not exists display_name text;

update public.household_members hm
set display_name = coalesce(
  nullif(u.raw_user_meta_data->>'name',''),
  split_part(u.email,'@',1)
)
from auth.users u
where hm.user_id=u.id
  and (hm.display_name is null or trim(hm.display_name)='');

create table if not exists public.member_settings (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  month text not null,
  salary numeric not null default 0 check (salary >= 0),
  primary key (household_id,user_id,month)
);

alter table public.member_settings enable row level security;

drop policy if exists ms_select on public.member_settings;
drop policy if exists ms_insert on public.member_settings;
drop policy if exists ms_update on public.member_settings;
drop policy if exists ms_delete on public.member_settings;

create policy ms_select on public.member_settings
for select to authenticated
using (public.is_member(household_id));

create policy ms_insert on public.member_settings
for insert to authenticated
with check (public.is_member(household_id) and user_id=auth.uid());

create policy ms_update on public.member_settings
for update to authenticated
using (public.is_member(household_id) and user_id=auth.uid())
with check (public.is_member(household_id) and user_id=auth.uid());

create policy ms_delete on public.member_settings
for delete to authenticated
using (public.is_member(household_id) and user_id=auth.uid());

-- Migra o salário antigo para o dono do espaço, sem apagar o dado antigo.
insert into public.member_settings(household_id,user_id,month,salary)
select hs.household_id,h.owner_id,hs.month,hs.salary
from public.household_settings hs
join public.households h on h.id=hs.household_id
on conflict (household_id,user_id,month) do nothing;

alter table public.expenses
  add column if not exists owner_scope text not null default 'member',
  add column if not exists owner_user_id uuid references auth.users(id);

alter table public.pending_items
  add column if not exists owner_scope text not null default 'member',
  add column if not exists owner_user_id uuid references auth.users(id);

-- Lançamentos antigos passam a pertencer à pessoa que os adicionou.
update public.expenses
set owner_scope='member',
    owner_user_id=coalesce(owner_user_id,author_id)
where owner_user_id is null and owner_scope <> 'shared';

update public.pending_items
set owner_scope='member',
    owner_user_id=coalesce(owner_user_id,author_id)
where owner_user_id is null and owner_scope <> 'shared';

drop policy if exists m_update_own on public.household_members;
create policy m_update_own on public.household_members
for update to authenticated
using (user_id=auth.uid())
with check (user_id=auth.uid());

create or replace function public.set_my_display_name_v7(
  p_household_id uuid,
  p_display_name text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
 if not public.is_member(p_household_id) then
   raise exception 'Você não pertence a este espaço';
 end if;
 update public.household_members
 set display_name=left(trim(p_display_name),60)
 where household_id=p_household_id and user_id=auth.uid();
end;
$$;

create or replace function public.create_household_v7(
  p_name text,
  p_invite_code text,
  p_display_name text
)
returns public.households
language plpgsql
security definer
set search_path=public
as $$
declare h public.households;
begin
 insert into public.households(name,invite_code,owner_id)
 values (left(trim(p_name),80),upper(trim(p_invite_code)),auth.uid())
 returning * into h;

 insert into public.household_members(household_id,user_id,display_name)
 values(h.id,auth.uid(),left(trim(p_display_name),60))
 on conflict(household_id,user_id)
 do update set display_name=excluded.display_name;

 return h;
end;
$$;

create or replace function public.join_household_v7(
  p_invite_code text,
  p_display_name text
)
returns public.households
language plpgsql
security definer
set search_path=public
as $$
declare h public.households;
begin
 select * into h
 from public.households
 where invite_code=upper(trim(p_invite_code));

 if h.id is null then
   raise exception 'Código de convite inválido';
 end if;

 insert into public.household_members(household_id,user_id,display_name)
 values(h.id,auth.uid(),left(trim(p_display_name),60))
 on conflict(household_id,user_id)
 do update set display_name=excluded.display_name;

 return h;
end;
$$;

revoke all on function public.set_my_display_name_v7(uuid,text) from public;
revoke all on function public.create_household_v7(text,text,text) from public;
revoke all on function public.join_household_v7(text,text) from public;

grant execute on function public.set_my_display_name_v7(uuid,text) to authenticated;
grant execute on function public.create_household_v7(text,text,text) to authenticated;
grant execute on function public.join_household_v7(text,text) to authenticated;

alter table public.expenses replica identity full;
alter table public.pending_items replica identity full;
alter table public.member_settings replica identity full;
alter table public.household_members replica identity full;

do $$
begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='expenses') then
   alter publication supabase_realtime add table public.expenses;
 end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pending_items') then
   alter publication supabase_realtime add table public.pending_items;
 end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='member_settings') then
   alter publication supabase_realtime add table public.member_settings;
 end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='household_members') then
   alter publication supabase_realtime add table public.household_members;
 end if;
end $$;
