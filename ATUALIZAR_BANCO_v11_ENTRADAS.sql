-- MEU DINHEIRO v11 - ENTRADAS EXTRAS
-- Rode UMA VEZ no SQL Editor do Supabase.

create table if not exists public.extra_income (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  value numeric(12,2) not null check (value > 0),
  month text not null,
  created_at timestamptz not null default now()
);

create index if not exists extra_income_household_month_idx
on public.extra_income(household_id, month);

alter table public.extra_income enable row level security;

drop policy if exists income_select on public.extra_income;
drop policy if exists income_insert on public.extra_income;
drop policy if exists income_update on public.extra_income;
drop policy if exists income_delete on public.extra_income;

create policy income_select on public.extra_income
for select to authenticated
using (public.is_member(household_id));

create policy income_insert on public.extra_income
for insert to authenticated
with check (public.is_member(household_id) and user_id=auth.uid());

create policy income_update on public.extra_income
for update to authenticated
using (public.is_member(household_id) and user_id=auth.uid())
with check (public.is_member(household_id) and user_id=auth.uid());

create policy income_delete on public.extra_income
for delete to authenticated
using (public.is_member(household_id) and user_id=auth.uid());

alter table public.extra_income replica identity full;

do $$
begin
 if not exists(
   select 1 from pg_publication_tables
   where pubname='supabase_realtime' and schemaname='public' and tablename='extra_income'
 ) then
   alter publication supabase_realtime add table public.extra_income;
 end if;
end $$;
