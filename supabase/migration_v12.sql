-- ============================================================
-- Migration v12 — KSJ Swimming: show pre-tracking cancellations too
-- Run AFTER migration_v11.sql in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
-- v11 only listed cancellations tagged cancelled_by='client'. Every
-- cancellation made BEFORE v11 ran is untagged (null) — 71 of them here —
-- so the panel started empty even though 30 were within the window.
--
-- Those rows are genuinely of unknown origin: some were clients using
-- their cancel link, some were staff cancelling a slot. We can't tell
-- retroactively and we will not guess, because guessing "client" would
-- imply families flaked in a panel that sits beside the late-cancel
-- tracker. So they are now INCLUDED but flagged: cancelled_by comes back
-- in the payload and the UI labels null as "before tracking".
--
-- Rows tagged 'staff' stay excluded — those are known not to be a
-- client freeing up a slot.
-- ============================================================

create or replace function public.get_recent_cancellations(
  p_days int default 14,
  p_coach_id uuid default null,
  p_only_open boolean default false
) returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;
  if p_days is null or p_days < 1 or p_days > 90 then
    p_days := 14;
  end if;

  select coalesce(json_agg(row_to_json(t) order by t.cancelled_at desc), '[]'::json)
  into v_result
  from (
    select b.id,
           b.cancelled_at,
           b.cancelled_by,        -- 'client' | null (pre-v11, origin unknown)
           b.student_name,
           b.first_name,
           b.email,
           b.phone,
           b.parent_name,
           s.id           as slot_id,
           s.starts_at,
           s.duration_min,
           s.status       as slot_status,
           s.coach_id,
           po.name        as pool_name,
           coalesce(pr.display_name, 'Unassigned') as coach,
           case when s.starts_at > b.cancelled_at
                then extract(epoch from (s.starts_at - b.cancelled_at))::bigint
                else null end as seconds_before
    from public.bookings b
    join public.slots s   on s.id = b.slot_id
    join public.pools po  on po.id = s.pool_id
    left join public.profiles pr on pr.id = s.coach_id
    where b.status = 'cancelled'
      -- 'client' and untagged-legacy rows; known staff cancellations excluded
      and b.cancelled_by is distinct from 'staff'
      and b.cancelled_at is not null
      and b.cancelled_at >= now() - make_interval(days => p_days)
      and (p_coach_id is null or s.coach_id = p_coach_id)
      and (not p_only_open or s.status = 'open')
  ) t;

  return json_build_object('cancellations', v_result);
end;
$$;

revoke all on function public.get_recent_cancellations(int, uuid, boolean) from public;
revoke execute on function public.get_recent_cancellations(int, uuid, boolean) from anon;
grant execute on function public.get_recent_cancellations(int, uuid, boolean) to authenticated;
