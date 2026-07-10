-- ============================================================
-- Migration v7 — KSJ Swimming
-- Run AFTER migration_v6.sql in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
--   1. get_revenue_grid v2: every (dow, hour) cell now also carries a
--      per-coach breakdown — coaches: [{coach, lessons, revenue}] —
--      including "Unassigned" for slots with no coach. Same signature,
--      same admin-only SECURITY DEFINER gate; cell lessons/revenue
--      totals are unchanged, so the existing grid keeps working even
--      if an older staff.html is still deployed.
--   2. (Calendar hours-per-coach summary is frontend-only — it reads
--      the slots the calendar already fetches. No DB changes.)
-- ============================================================

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
    perform now() at time zone p_tz;   -- raises for an unknown zone name
  exception when others then
    raise exception 'Unknown timezone: %', p_tz;
  end;

  select json_build_object(
    'cells', coalesce(json_agg(row_to_json(cell)), '[]'::json)
  ) into v_result
  from (
    select dow, hour,
           sum(lessons)::int as lessons,
           sum(revenue)      as revenue,
           json_agg(json_build_object(
             'coach', coach, 'lessons', lessons, 'revenue', revenue
           ) order by revenue desc, coach) as coaches
    from (
      select extract(isodow from s.starts_at at time zone p_tz)::int as dow,  -- 1=Mon … 7=Sun
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
  ) cell;

  return v_result;
end;
$$;

-- CREATE OR REPLACE keeps existing ACLs, but re-assert them anyway so
-- this file stands alone: admin gate inside, anon can't even execute.
revoke all on function public.get_revenue_grid(timestamptz, timestamptz, text) from public;
revoke execute on function public.get_revenue_grid(timestamptz, timestamptz, text) from anon;
grant execute on function public.get_revenue_grid(timestamptz, timestamptz, text) to authenticated;
