alter table public.employees
  alter column office drop not null;

alter table public.employees
  add column if not exists employee_code text;

with code_pool as (
  select
    chr(65 + ((n - 1) / 10)::int) || ((n - 1) % 10)::text as code,
    n
  from generate_series(1, 260) as gs(n)
),
ranked_employees as (
  select
    id,
    row_number() over (order by created_at, name, coalesce(office, ''), id) as rn
  from public.employees
  where employee_code is null
),
assignments as (
  select
    re.id,
    cp.code
  from ranked_employees re
  join code_pool cp on cp.n = re.rn
)
update public.employees e
set employee_code = a.code
from assignments a
where e.id = a.id;

create unique index if not exists employees_employee_code_key
  on public.employees(employee_code);

create table if not exists public.comp_leave_holidays (
  id uuid primary key default gen_random_uuid(),
  holiday_date date not null unique,
  holiday_name text not null,
  note text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.comp_leave_earned
  add column if not exists office text,
  add column if not exists shift_type text,
  add column if not exists start_hour numeric(10,3),
  add column if not exists end_hour numeric(10,3),
  add column if not exists note text,
  add column if not exists entry_source text not null default 'legacy';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'comp_leave_earned_entry_source_check'
  ) then
    alter table public.comp_leave_earned
      add constraint comp_leave_earned_entry_source_check
      check (entry_source in ('legacy', 'portal'));
  end if;
end
$$;

create index if not exists comp_leave_holidays_active_idx
  on public.comp_leave_holidays(is_active, holiday_date);

create index if not exists comp_leave_earned_holiday_idx
  on public.comp_leave_earned(holiday_date desc, employee_id);

alter table public.comp_leave_holidays enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'employees'
      and policyname = 'employees_insert_all'
  ) then
    create policy employees_insert_all
      on public.employees
      for insert
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'employees'
      and policyname = 'employees_update_all'
  ) then
    create policy employees_update_all
      on public.employees
      for update
      using (true)
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_earned'
      and policyname = 'comp_leave_earned_insert_all'
  ) then
    create policy comp_leave_earned_insert_all
      on public.comp_leave_earned
      for insert
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_earned'
      and policyname = 'comp_leave_earned_update_all'
  ) then
    create policy comp_leave_earned_update_all
      on public.comp_leave_earned
      for update
      using (true)
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_usage'
      and policyname = 'comp_leave_usage_update_all'
  ) then
    create policy comp_leave_usage_update_all
      on public.comp_leave_usage
      for update
      using (true)
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_holidays'
      and policyname = 'comp_leave_holidays_select_all'
  ) then
    create policy comp_leave_holidays_select_all
      on public.comp_leave_holidays
      for select
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_holidays'
      and policyname = 'comp_leave_holidays_insert_all'
  ) then
    create policy comp_leave_holidays_insert_all
      on public.comp_leave_holidays
      for insert
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_holidays'
      and policyname = 'comp_leave_holidays_update_all'
  ) then
    create policy comp_leave_holidays_update_all
      on public.comp_leave_holidays
      for update
      using (true)
      with check (true);
  end if;
end
$$;

grant select, insert, update on public.employees to anon, authenticated;
grant select, insert, update on public.comp_leave_earned to anon, authenticated;
grant select, insert, update on public.comp_leave_usage to anon, authenticated;
grant select, insert, update on public.comp_leave_holidays to anon, authenticated;
