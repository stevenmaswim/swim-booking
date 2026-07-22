-- ============================================================
-- Migration v9 — KSJ Swimming: RAIN-OUT TRACKING
-- Run AFTER migration_v8.sql in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
-- Outdoor lessons cancelled by weather are a distinct state:
--   * slots.status and bookings.status gain 'rained_out'. The booking
--     row is KEPT — a rain-out is never a client cancellation and must
--     never count toward late-cancel stats (the cancelled_at trigger
--     only fires for status='cancelled', so it stays null).
--   * slots.rained_out_at / rained_out_by record who marked it, when.
--     Neither column has an API write grant — only the RPCs below.
--   * rain_out_slot(): coach on own slots, admin on any.
--   * rain_out_day(): ADMIN-ONLY bulk (whole local day, optional pool
--     filter) with p_dry_run=true returning counts for the confirm UI.
--   * undo_rain_out(): admin-only; restores a booked slot's booking;
--     blocked once the slot time has passed.
--   * Revenue: get_revenue_grid/report v3 keep excluding everything
--     non-confirmed, and now also return a "rained out" summary
--     (lessons + unrealized $) so owners see the weather impact.
--   * Public visibility: the anon slots policy shows only
--     open/booked, so rained-out slots disappear from book.html
--     automatically. Reminder emails filter status='confirmed', so
--     rained-out bookings never get reminders.
-- ============================================================

-- ---------- 1. Status values + audit columns ----------
alter table public.slots drop constraint if exists slots_status_check;
alter table public.slots add constraint slots_status_check
  check (status in ('open', 'booked', 'cancelled', 'rained_out'));

alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings add constraint bookings_status_check
  check (status in ('confirmed', 'cancelled', 'rained_out'));

alter table public.slots add column if not exists rained_out_at timestamptz;
alter table public.slots add column if not exists rained_out_by uuid references public.profiles (id);
-- No grants for the new columns: staff read slots via RLS with full column
-- access as `authenticated`?  No — slots SELECT is column-granted; extend it
-- so the dashboard can display who/when, but writes stay RPC-only.
grant select (rained_out_at, rained_out_by) on public.slots to authenticated;

-- ---------- 2. Mark one slot (coach: own; admin: any) ----------
create or replace function public.rain_out_slot(p_slot_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
  v_booking_id uuid;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;
  select * into v_slot from public.slots where id = p_slot_id for update;
  if not found then
    raise exception 'Slot not found.';
  end if;
  if not (public.is_admin() or v_slot.coach_id = auth.uid()) then
    raise exception 'You can only rain out your own slots.';
  end if;
  if v_slot.status not in ('open', 'booked') then
    raise exception 'Only open or booked slots can be rained out.';
  end if;
  -- Same-day retroactive marking is fine (storm mid-lesson); older is not.
  if v_slot.starts_at < now() - interval '24 hours' then
    raise exception 'This lesson is too far in the past to rain out.';
  end if;

  update public.bookings set status = 'rained_out'
  where slot_id = p_slot_id and status = 'confirmed'
  returning id into v_booking_id;

  update public.slots
  set status = 'rained_out', rained_out_at = now(), rained_out_by = auth.uid()
  where id = p_slot_id;

  return json_build_object('ok', true, 'booking_id', v_booking_id);
end;
$$;

revoke all on function public.rain_out_slot(uuid) from public;
revoke execute on function public.rain_out_slot(uuid) from anon;
grant execute on function public.rain_out_slot(uuid) to authenticated;

-- ---------- 3. Bulk: rain out a whole (local) day — ADMIN ONLY ----------
-- p_dry_run=true only counts, so the UI can confirm before acting.
create or replace function public.rain_out_day(
  p_day date,
  p_pool_id uuid default null,
  p_dry_run boolean default false,
  p_tz text default 'America/Chicago'
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open int;
  v_booked int;
  v_booking_ids jsonb;
begin
  if not public.is_admin() then
    raise exception 'Only admins can rain out a whole day.';
  end if;
  begin
    perform now() at time zone p_tz;
  exception when others then
    raise exception 'Unknown timezone: %', p_tz;
  end;
  if p_day is null or p_day < (now() at time zone p_tz)::date - 1 then
    raise exception 'Pick today, yesterday, or a future date.';
  end if;

  select count(*) filter (where status = 'open'),
         count(*) filter (where status = 'booked')
  into v_open, v_booked
  from public.slots
  where (starts_at at time zone p_tz)::date = p_day
    and status in ('open', 'booked')
    and (p_pool_id is null or pool_id = p_pool_id);

  if p_dry_run then
    return json_build_object('dry_run', true, 'open', v_open, 'booked', v_booked);
  end if;

  -- Mark bookings first (they reference slots still in open/booked state)
  with affected as (
    select id from public.slots
    where (starts_at at time zone p_tz)::date = p_day
      and status in ('open', 'booked')
      and (p_pool_id is null or pool_id = p_pool_id)
    for update
  ), b as (
    update public.bookings set status = 'rained_out'
    where slot_id in (select id from affected) and status = 'confirmed'
    returning id
  ), s as (
    update public.slots
    set status = 'rained_out', rained_out_at = now(), rained_out_by = auth.uid()
    where id in (select id from affected)
    returning 1
  )
  select coalesce(jsonb_agg(b.id), '[]'::jsonb) into v_booking_ids from b;

  return json_build_object(
    'dry_run', false, 'open', v_open, 'booked', v_booked,
    'booking_ids', v_booking_ids
  );
end;
$$;

revoke all on function public.rain_out_day(date, uuid, boolean, text) from public;
revoke execute on function public.rain_out_day(date, uuid, boolean, text) from anon;
grant execute on function public.rain_out_day(date, uuid, boolean, text) to authenticated;

-- ---------- 4. Undo (weather cleared) — ADMIN ONLY, future slots ----------
create or replace function public.undo_rain_out(p_slot_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
  v_booking public.bookings%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only admins can undo a rain-out.';
  end if;
  select * into v_slot from public.slots where id = p_slot_id for update;
  if not found then
    raise exception 'Slot not found.';
  end if;
  if v_slot.status <> 'rained_out' then
    raise exception 'This slot is not rained out.';
  end if;
  if v_slot.starts_at <= now() then
    raise exception 'This lesson time has passed — publish a new slot instead.';
  end if;

  select * into v_booking from public.bookings
  where slot_id = p_slot_id and status = 'rained_out'
  order by created_at desc limit 1;

  if v_booking.id is not null then
    update public.bookings set status = 'confirmed' where id = v_booking.id;
    update public.slots
    set status = 'booked',
        booked_by_display = v_booking.first_name || ' ' || upper(left(v_booking.last_name, 1)) || '.',
        rained_out_at = null, rained_out_by = null
    where id = p_slot_id;
    return json_build_object('ok', true, 'restored', 'booked', 'booking_id', v_booking.id);
  else
    update public.slots
    set status = 'open', rained_out_at = null, rained_out_by = null
    where id = p_slot_id;
    return json_build_object('ok', true, 'restored', 'open');
  end if;
end;
$$;

revoke all on function public.undo_rain_out(uuid) from public;
revoke execute on function public.undo_rain_out(uuid) from anon;
grant execute on function public.undo_rain_out(uuid) to authenticated;

-- ---------- 5. Revenue grid v3: + rained-out summary ----------
create or replace function public.get_revenue_grid(
  p_from timestamptz,
  p_to timestamptz,
  p_tz text default 'America/Chicago'
) returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_admin() then
    raise exception 'Only admins can view revenue.';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'Please choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Please choose a range of 400 days or less.';
  end if;
  begin
    perform now() at time zone p_tz;
  exception when others then
    raise exception 'Unknown timezone: %', p_tz;
  end;

  select json_build_object(
    'cells', coalesce((
      select json_agg(row_to_json(cell))
      from (
        select dow, hour,
               sum(lessons)::int as lessons,
               sum(revenue)      as revenue,
               json_agg(json_build_object(
                 'coach', coach, 'lessons', lessons, 'revenue', revenue
               ) order by revenue desc, coach) as coaches
        from (
          select extract(isodow from s.starts_at at time zone p_tz)::int as dow,
                 extract(hour   from s.starts_at at time zone p_tz)::int as hour,
                 coalesce(pr.display_name, 'Unassigned') as coach,
                 count(*)::int as lessons,
                 sum(s.price)  as revenue
          from public.bookings b
          join public.slots s on s.id = b.slot_id
          left join public.profiles pr on pr.id = s.coach_id
          where b.status = 'confirmed'
            and s.starts_at >= p_from and s.starts_at < p_to
          group by 1, 2, 3
        ) per_coach
        group by dow, hour
      ) cell), '[]'::json),
    -- weather impact: lessons that WERE booked but got rained out
    'rained', (
      select json_build_object(
        'lessons', count(*)::int,
        'revenue', coalesce(sum(s.price), 0))
      from public.bookings b
      join public.slots s on s.id = b.slot_id
      where b.status = 'rained_out'
        and s.starts_at >= p_from and s.starts_at < p_to
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_revenue_grid(timestamptz, timestamptz, text) from public;
revoke execute on function public.get_revenue_grid(timestamptz, timestamptz, text) from anon;
grant execute on function public.get_revenue_grid(timestamptz, timestamptz, text) to authenticated;

-- ---------- 6. Revenue report v3: rained-out per period + totals ----------
drop function if exists public.get_revenue_report(text, int, uuid);

create or replace function public.get_revenue_report(
  p_period text default 'week',
  p_year int default null,
  p_coach_id uuid default null
) returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_admin() then
    raise exception 'Only admins can view revenue.';
  end if;
  if p_period not in ('week', 'month', 'year') then
    raise exception 'period must be ''week'', ''month'' or ''year''';
  end if;

  select json_build_object(
    'total_lessons', (select count(*) from public.bookings b
        join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)),
    'total_revenue', (select coalesce(sum(s.price), 0) from public.bookings b
        join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)),
    'rained_lessons', (select count(*) from public.bookings b
        join public.slots s on s.id = b.slot_id
        where b.status = 'rained_out'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)),
    'rained_revenue', (select coalesce(sum(s.price), 0) from public.bookings b
        join public.slots s on s.id = b.slot_id
        where b.status = 'rained_out'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)),
    'years', (select coalesce(json_agg(y order by y desc), '[]'::json) from (
        select distinct extract(year from s.starts_at)::int as y
        from public.bookings b join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed') yr),
    'by_period', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select date_trunc(p_period, s.starts_at) as period,
               count(*) filter (where b.status = 'confirmed') as lessons,
               coalesce(sum(s.price) filter (where b.status = 'confirmed'), 0) as revenue,
               count(*) filter (where b.status = 'rained_out') as rained_lessons,
               coalesce(sum(s.price) filter (where b.status = 'rained_out'), 0) as rained_revenue
        from public.bookings b join public.slots s on s.id = b.slot_id
        where b.status in ('confirmed', 'rained_out')
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)
        group by 1
        having count(*) filter (where b.status = 'confirmed') > 0
            or count(*) filter (where b.status = 'rained_out') > 0
        order by 1 desc limit 60) t),
    'by_coach', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select coalesce(p.display_name, 'Unassigned') as coach,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b
        join public.slots s on s.id = b.slot_id
        left join public.profiles p on p.id = s.coach_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)
        group by 1 order by 3 desc) t),
    'by_pool', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select po.name as pool,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b
        join public.slots s on s.id = b.slot_id
        join public.pools po on po.id = s.pool_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)
        group by 1 order by 3 desc) t)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_revenue_report(text, int, uuid) from public;
revoke execute on function public.get_revenue_report(text, int, uuid) from anon;
grant execute on function public.get_revenue_report(text, int, uuid) to authenticated;
