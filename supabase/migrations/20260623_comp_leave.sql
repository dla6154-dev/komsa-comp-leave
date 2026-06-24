create extension if not exists pgcrypto;

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  office text not null,
  status text not null default 'active',
  retired_date date,
  created_at timestamptz not null default now(),
  constraint employees_status_check check (status in ('active', 'retired')),
  constraint employees_name_office_key unique (name, office)
);

create table if not exists public.comp_leave_earned (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  holiday_date date not null,
  holiday_name text not null,
  earned_hours numeric(10,3) not null,
  created_at timestamptz not null default now(),
  constraint comp_leave_earned_unique unique (employee_id, holiday_date, holiday_name)
);

create table if not exists public.comp_leave_usage (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  used_date date not null,
  used_hours numeric(10,3) not null,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists employees_status_idx on public.employees(status, office, name);
create index if not exists comp_leave_earned_employee_idx on public.comp_leave_earned(employee_id, holiday_date desc);
create index if not exists comp_leave_usage_employee_idx on public.comp_leave_usage(employee_id, used_date desc, created_at desc);

create or replace function public.calc_comp_leave_hours(
  start_hour numeric,
  end_hour numeric,
  overtime_hours numeric default null,
  overtime_night_hours numeric default null
)
returns numeric
language plpgsql
immutable
as $$
declare
  k numeric := start_hour;
  l numeric := end_hour;
  p numeric;
  m numeric;
  n numeric;
  o numeric;
  q numeric;
  base numeric;
  m2 constant numeric := 6;
  n2 constant numeric := 22;
  o1 constant numeric := 13;
  o2 constant numeric := 1;
  p1 constant numeric := 24;
  m1 constant numeric := 2;
begin
  if start_hour is null or end_hour is null then
    raise exception 'start_hour and end_hour are required';
  end if;

  if start_hour < 0 or start_hour > 24 or end_hour < 0 or end_hour > 24 then
    raise exception 'start_hour and end_hour must be between 0 and 24';
  end if;

  if coalesce(overtime_hours, 0) > 0 and coalesce(overtime_night_hours, 0) > 0 then
    raise exception 'overtime_hours and overtime_night_hours cannot both be populated';
  end if;

  p := case
    when l > k then l - k
    else l + p1 - k
  end;

  if k < m2 then
    m := m2 - k;
  elsif k > n2 then
    m := k - n2;
  elsif k <= n2 and l <= m2 then
    m := m1;
  else
    m := 0;
  end if;

  if l > n2 then
    n := l - n2;
  elsif l <= m2 then
    n := l;
  else
    n := 0;
  end if;

  o := case when k < o1 then o2 else 0 end;
  q := m + n + p - o;
  base := q / 2;

  if coalesce(overtime_hours, 0) > 0 then
    return base + overtime_hours * 2;
  end if;

  if coalesce(overtime_night_hours, 0) > 0 then
    return base + overtime_night_hours * 3;
  end if;

  return base;
end;
$$;

create or replace function public.add_comp_leave_earned(
  p_employee_id uuid,
  p_holiday_date date,
  p_holiday_name text,
  p_start_hour numeric,
  p_end_hour numeric,
  p_overtime_hours numeric default null,
  p_overtime_night_hours numeric default null
)
returns public.comp_leave_earned
language plpgsql
security invoker
as $$
declare
  inserted_row public.comp_leave_earned;
begin
  insert into public.comp_leave_earned (
    employee_id,
    holiday_date,
    holiday_name,
    earned_hours
  )
  values (
    p_employee_id,
    p_holiday_date,
    p_holiday_name,
    public.calc_comp_leave_hours(
      p_start_hour,
      p_end_hour,
      p_overtime_hours,
      p_overtime_night_hours
    )
  )
  on conflict (employee_id, holiday_date, holiday_name) do update
    set earned_hours = excluded.earned_hours
  returning * into inserted_row;

  return inserted_row;
end;
$$;

create or replace view public.comp_leave_balances as
select
  e.id as employee_id,
  e.name,
  e.office,
  e.status,
  e.retired_date,
  coalesce(earned.total_earned_hours, 0) as total_earned_hours,
  coalesce(usage.total_used_hours, 0) as total_used_hours,
  coalesce(earned.total_earned_hours, 0) - coalesce(usage.total_used_hours, 0) as balance_hours
from public.employees e
left join lateral (
  select sum(cle.earned_hours) as total_earned_hours
  from public.comp_leave_earned cle
  where cle.employee_id = e.id
) earned on true
left join lateral (
  select sum(clu.used_hours) as total_used_hours
  from public.comp_leave_usage clu
  where clu.employee_id = e.id
) usage on true;

alter table public.employees enable row level security;
alter table public.comp_leave_earned enable row level security;
alter table public.comp_leave_usage enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'employees'
      and policyname = 'employees_select_all'
  ) then
    create policy employees_select_all
      on public.employees
      for select
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_earned'
      and policyname = 'comp_leave_earned_select_all'
  ) then
    create policy comp_leave_earned_select_all
      on public.comp_leave_earned
      for select
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_usage'
      and policyname = 'comp_leave_usage_select_all'
  ) then
    create policy comp_leave_usage_select_all
      on public.comp_leave_usage
      for select
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'comp_leave_usage'
      and policyname = 'comp_leave_usage_insert_all'
  ) then
    create policy comp_leave_usage_insert_all
      on public.comp_leave_usage
      for insert
      with check (true);
  end if;
end
$$;

grant select on public.employees to anon, authenticated;
grant select on public.comp_leave_earned to anon, authenticated;
grant select, insert on public.comp_leave_usage to anon, authenticated;
grant select on public.comp_leave_balances to anon, authenticated;
grant execute on function public.calc_comp_leave_hours(numeric, numeric, numeric, numeric) to anon, authenticated;
grant execute on function public.add_comp_leave_earned(uuid, date, text, numeric, numeric, numeric, numeric) to anon, authenticated;
grant usage on schema public to anon, authenticated;
