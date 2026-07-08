-- ============================================================
-- Migration: security hardening (audit 2026-07-08)
-- Run AFTER all previous migrations in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
-- Addresses audit findings L1–L6 (and supports M5). Does NOT change
-- any behaviour of the public site — only tightens who can reach what.
-- ============================================================

-- ---------- L1: stop anonymous users reading profiles.role / internals ----------
-- Public pages only need name, bio, photo, and the public flag. Hiding
-- `role` stops outsiders learning which coaches are admins. Staff
-- (authenticated) keep full access via their existing grants + RLS.
revoke select on table public.profiles from anon;
grant select (id, display_name, bio, is_public, photo_url) on public.profiles to anon;

-- ---------- L2: remove leftover anon table privileges (RLS was the only barrier) ----------
-- staff_emails is the allowlist that grants dashboard access; it must be
-- completely unreachable via the API (is_staff() reads it as SECURITY DEFINER).
revoke all on table public.staff_emails from anon, authenticated;
-- bookings/clients are only ever touched through SECURITY DEFINER functions
-- for the public; staff go through RLS as `authenticated`.
revoke all on table public.bookings from anon;
revoke all on table public.clients  from anon;

-- ---------- L3: admin/staff-only functions must not be callable by anon ----------
-- (Supabase grants EXECUTE to anon by default; the internal checks already
-- blocked misuse, but we remove the ability to call them at all.)
revoke execute on function public.is_admin()                              from anon;
revoke execute on function public.is_staff()                              from anon;
revoke execute on function public.get_revenue_report(text, int, uuid)     from anon;
revoke execute on function public.delete_client(uuid)                     from anon;
-- (book_slot, cancel_booking, verify_and_list_bookings stay callable by anon.)

-- ---------- L4: storage — only image files under coaches/ or pools/ ----------
-- Best-effort: some projects don't allow altering storage policies via SQL.
do $$
begin
  drop policy if exists "photos staff upload" on storage.objects;
  drop policy if exists "photos staff update" on storage.objects;
  create policy "photos staff upload" on storage.objects
    for insert to authenticated
    with check (
      bucket_id = 'photos' and public.is_staff()
      and name ~* '^(coaches|pools)/[^/]+\.(jpg|jpeg|png|webp)$'
    );
  create policy "photos staff update" on storage.objects
    for update to authenticated
    using (bucket_id = 'photos' and public.is_staff())
    with check (
      bucket_id = 'photos' and public.is_staff()
      and name ~* '^(coaches|pools)/[^/]+\.(jpg|jpeg|png|webp)$'
    );
exception when insufficient_privilege or undefined_table then
  raise notice 'Could not tighten storage policies via SQL — set them in Dashboard > Storage > photos > Policies (allow INSERT/UPDATE only for image files under coaches/ or pools/).';
end $$;

-- ---------- L6 + M5: data-retention helpers ----------
-- Safe housekeeping: delete used/expired login codes. Schedule hourly, or
-- let it piggyback on the reminder cron.
create or replace function public.purge_expired_otps()
returns int
language sql
security definer
set search_path = public
as $$
  with d as (delete from public.booking_otps where expires_at < now() returning 1)
  select count(*)::int from d;
$$;
revoke all on function public.purge_expired_otps() from public;
revoke execute on function public.purge_expired_otps() from anon;
grant execute on function public.purge_expired_otps() to authenticated;

-- Retention: anonymize personal details on lessons older than N months
-- (keeps slot/price so revenue totals stay correct), then drop clients
-- that no longer have any linked booking. Admin-only. NOT scheduled —
-- pick a retention window and schedule it (see SECURITY_AUDIT.md / README).
create or replace function public.purge_old_client_data(p_months int default 24)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_admin() then
    raise exception 'Only admins can purge client data.';
  end if;
  with d as (
    update public.bookings b
    set student_name = '[purged]', first_name = '', last_name = '', parent_name = '',
        email = 'purged+' || b.id::text || '@redacted.invalid', phone = '', client_id = null
    from public.slots s
    where s.id = b.slot_id
      and s.starts_at < now() - make_interval(months => p_months)
      and b.email not like 'purged+%'
    returning 1)
  select count(*)::int into n from d;
  delete from public.clients c
  where not exists (select 1 from public.bookings b where b.client_id = c.id);
  return n;
end;
$$;
revoke all on function public.purge_old_client_data(int) from public;
revoke execute on function public.purge_old_client_data(int) from anon;
grant execute on function public.purge_old_client_data(int) to authenticated;
