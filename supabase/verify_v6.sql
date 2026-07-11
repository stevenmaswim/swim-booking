-- ============================================================
-- verify_v6.sql — post-migration verification for migration_v6.sql
-- Paste the WHOLE file into Supabase Dashboard > SQL Editor and run.
--
-- HOW TO READ THE OUTPUT: the run ends with an ERROR — that is
-- intentional. The "error" message IS the report (the SQL editor
-- hides RAISE NOTICE output, and ending in an exception also forces
-- Postgres to roll back every fixture this script created — no test
-- data survives). Read the PASS/FAIL lines inside the error message;
-- the first line is the summary.
--
-- It simulates JWTs with set_config(), which exercises the same RLS
-- policies and SECURITY DEFINER gates the REST API hits. For a belt-
-- and-braces check with REAL tokens, also run verify_v6_api.mjs.
-- ============================================================
do $$
declare
  rep text := '';
  npass int := 0;
  nfail int := 0;
  v_admin uuid := '11111111-1111-1111-1111-111111111111';
  v_coach uuid := '22222222-2222-2222-2222-222222222222';
  v_pool  uuid := '33333333-3333-3333-3333-333333333333';
  r json;
  n int;
  v numeric;
  b record;
  tok text;

  -- (plpgsql has no local procedures — the ok/bad pattern is inlined:
  --  ok  → rep := rep || E'\nPASS  <label>'; npass := npass + 1;
  --  bad → rep := rep || E'\nFAIL  <label>'; nfail := nfail + 1;)
begin
  -- ==================== fixtures (all rolled back at the end) ====================
  insert into public.staff_emails (email) values
    ('vtest-admin@example.com'), ('vtest-coach@example.com')
  on conflict do nothing;

  -- Minimal auth users; the on_auth_user_created trigger builds profiles.
  begin
    insert into auth.users (instance_id, id, aud, role, email)
    values ('00000000-0000-0000-0000-000000000000', v_admin, 'authenticated', 'authenticated', 'vtest-admin@example.com'),
           ('00000000-0000-0000-0000-000000000000', v_coach, 'authenticated', 'authenticated', 'vtest-coach@example.com');
  exception when others then
    raise exception 'Could not create test users in auth.users (%). This Supabase project restricts direct auth writes — use verify_v6_api.mjs with real JWTs instead.', sqlerrm;
  end;
  update public.profiles set role = 'admin' where id = v_admin;

  insert into public.pools (id, name) values (v_pool, 'VTest Pool');

  -- Open slots tomorrow 10:00–20:00 + special-case slots
  insert into public.slots (id, pool_id, coach_id, starts_at, duration_min, price, created_by)
  select ('44444444-4444-4444-4444-4444444400' || lpad(g::text, 2, '0'))::uuid,
         v_pool, v_coach,
         date_trunc('day', now()) + interval '1 day' + make_interval(hours => 9 + g),
         60, 50, v_coach
  from generate_series(1, 11) g;
  insert into public.slots (id, pool_id, coach_id, starts_at, duration_min, price, status, created_by) values
    ('44444444-4444-4444-4444-444444440091', v_pool, v_coach, now() + interval '3 days', 60, 50, 'cancelled', v_coach),  -- reopen target
    ('44444444-4444-4444-4444-444444440092', v_pool, v_coach, now() - interval '3 days', 60, 50, 'cancelled', v_coach),  -- past, cancelled
    ('44444444-4444-4444-4444-444444440093', v_pool, v_admin, now() + interval '4 days', 60, 50, 'open',      v_admin),  -- admin-owned
    -- v8 fixtures: four slots at the SAME concurrent time (two-kids tests)
    ('44444444-4444-4444-4444-444444440096', v_pool, v_coach, now() + interval '30 hours', 60, 50, 'open', v_coach),
    ('44444444-4444-4444-4444-444444440097', v_pool, v_admin, now() + interval '30 hours', 60, 50, 'open', v_admin),
    ('44444444-4444-4444-4444-444444440098', v_pool, v_coach, now() + interval '30 hours', 60, 50, 'open', v_coach),
    ('44444444-4444-4444-4444-444444440099', v_pool, v_admin, now() + interval '30 hours', 60, 50, 'open', v_admin);

  -- OTP for the test client: code 123456
  insert into public.booking_otps (email, code_hash, expires_at)
  values ('vtest-client@example.com', encode(extensions.digest('123456', 'sha256'), 'hex'), now() + interval '10 minutes');

  -- ==================== A. book_slots behaviour ====================
  -- A1: no code, no token → must refuse
  begin
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440001","first_name":"Kid","last_name":"One"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000');
    rep := rep || E'\nFAIL  A1: booked without any email verification'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%verify your email%' then rep := rep || E'\nPASS  A1: verification required'; npass := npass + 1;
    else rep := rep || E'\nFAIL  A1: unexpected error: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  -- A2: five wrong codes → each returns {error}, attempts persist
  for n in 1..5 loop
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440001","first_name":"Kid","last_name":"One"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000', '000000');
    if r->>'error' is null then rep := rep || E'\nFAIL  A2: wrong code #' || n || ' accepted'; nfail := nfail + 1; end if;
  end loop;
  select attempts into n from public.booking_otps where email = 'vtest-client@example.com'
  order by created_at desc limit 1;
  if n = 5 then rep := rep || E'\nPASS  A2: 5 wrong codes recorded (attempts=5)'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A2: attempts=' || coalesce(n::text, 'null') || ' (expected 5 — increments must persist!)'; nfail := nfail + 1; end if;

  -- A3: now even the CORRECT code is locked out
  begin
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440001","first_name":"Kid","last_name":"One"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000', '123456');
    rep := rep || E'\nFAIL  A3: locked-out code still worked'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%Too many attempts%' then rep := rep || E'\nPASS  A3: wrong OTP 5x locks out'; npass := npass + 1;
    else rep := rep || E'\nFAIL  A3: unexpected error: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  -- fresh code after lockout (created_at nudged: now() is frozen in-txn
  -- and book_slots picks the NEWEST row)
  insert into public.booking_otps (email, code_hash, expires_at, created_at)
  values ('vtest-client@example.com', encode(extensions.digest('654321', 'sha256'), 'hex'),
          now() + interval '10 minutes', now() + interval '1 second');

  -- A4: book 3 slots atomically with the correct code
  r := public.book_slots(
       '[{"slot_id":"44444444-4444-4444-4444-444444440001","first_name":"Kid","last_name":"One"},
         {"slot_id":"44444444-4444-4444-4444-444444440002","first_name":"Kid","last_name":"One"},
         {"slot_id":"44444444-4444-4444-4444-444444440003","first_name":"Kid","last_name":"One"}]'::jsonb,
       'Parent One', 'vtest-client@example.com', '2045550000', '654321');
  if json_array_length(r->'bookings') = 3 and r->>'verify_token' is not null then
    rep := rep || E'\nPASS  A4: 3 slots booked in one call, 24h token issued'; npass := npass + 1;
  else
    rep := rep || E'\nFAIL  A4: ' || r::text; nfail := nfail + 1;
  end if;
  tok := r->>'verify_token';

  -- A5: steal test — one of the next two slots gets booked mid-flow
  update public.slots set status = 'booked' where id = '44444444-4444-4444-4444-444444440005';
  begin
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440004","first_name":"Kid","last_name":"One"},
           {"slot_id":"44444444-4444-4444-4444-444444440005","first_name":"Kid","last_name":"One"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
    rep := rep || E'\nFAIL  A5: booked through a stolen slot'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%was just taken%' then rep := rep || E'\nPASS  A5: steal detected and named (' || sqlerrm || ')'; npass := npass + 1;
    else rep := rep || E'\nFAIL  A5: unexpected error: ' || sqlerrm; nfail := nfail + 1; end if;
  end;
  select count(*) into n from public.bookings
  where slot_id in ('44444444-4444-4444-4444-444444440004', '44444444-4444-4444-4444-444444440005');
  if n = 0 then rep := rep || E'\nPASS  A5b: steal booked ZERO of the set'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A5b: ' || n || ' bookings leaked through'; nfail := nfail + 1; end if;

  -- A6: token reuse (no code) books without re-verification
  r := public.book_slots(
       '[{"slot_id":"44444444-4444-4444-4444-444444440006","first_name":"Kid","last_name":"One"}]'::jsonb,
       'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
  if json_array_length(r->'bookings') = 1 and r->>'verify_token' is null then
    rep := rep || E'\nPASS  A6: 24h token skips the code'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A6: ' || r::text; nfail := nfail + 1; end if;

  -- A7: cap of 8 upcoming — 4 booked so far, try 5 more
  begin
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440007","first_name":"Kid","last_name":"One"},
           {"slot_id":"44444444-4444-4444-4444-444444440008","first_name":"Kid","last_name":"One"},
           {"slot_id":"44444444-4444-4444-4444-444444440009","first_name":"Kid","last_name":"One"},
           {"slot_id":"44444444-4444-4444-4444-444444440010","first_name":"Kid","last_name":"One"},
           {"slot_id":"44444444-4444-4444-4444-444444440011","first_name":"Kid","last_name":"One"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
    rep := rep || E'\nFAIL  A7: exceeded the 8-upcoming cap (got 9)'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%8 upcoming bookings%' then rep := rep || E'\nPASS  A7: cap of 8 enforced'; npass := npass + 1;
    else rep := rep || E'\nFAIL  A7: unexpected error: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  -- A8 (v8): SAME-student overlap within the set is rejected, naming them
  update public.slots set starts_at = (select starts_at from public.slots where id = '44444444-4444-4444-4444-444444440007')
  where id = '44444444-4444-4444-4444-444444440008';
  begin
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440007","first_name":"Kid","last_name":"One"},
           {"slot_id":"44444444-4444-4444-4444-444444440008","first_name":"kid","last_name":"ONE"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
    rep := rep || E'\nFAIL  A8: same-student overlapping pair booked'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%overlap%' and sqlerrm like '%Kid%' then
      rep := rep || E'\nPASS  A8: same-student in-set overlap rejected by name (case-insensitive)'; npass := npass + 1;
    else rep := rep || E'\nFAIL  A8: unexpected error: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  -- ==================== A9–A11: v8 per-student overlap rule ====================
  -- A9: same email, TWO DIFFERENT kids, exact same 5 PM-style time → books BOTH
  r := public.book_slots(
       '[{"slot_id":"44444444-4444-4444-4444-444444440096","first_name":"Emma","last_name":"Test"},
         {"slot_id":"44444444-4444-4444-4444-444444440097","first_name":"Liam","last_name":"Test"}]'::jsonb,
       'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
  if json_array_length(r->'bookings') = 2 then
    rep := rep || E'\nPASS  A9: two different students book the SAME time on one email'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A9: ' || r::text; nfail := nfail + 1; end if;
  if (select booked_by_display from public.slots where id = '44444444-4444-4444-4444-444444440096') = 'Emma T.'
     and (select booked_by_display from public.slots where id = '44444444-4444-4444-4444-444444440097') = 'Liam T.' then
    rep := rep || E'\nPASS  A9b: public "First L." display is per-slot student'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A9b: booked_by_display not per-student'; nfail := nfail + 1; end if;

  -- A10: SAME student vs an EXISTING booking at that time → rejected by name
  begin
    r := public.book_slots(
         '[{"slot_id":"44444444-4444-4444-4444-444444440098","first_name":"Emma","last_name":"Test"}]'::jsonb,
         'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
    rep := rep || E'\nFAIL  A10: same student double-booked vs existing'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%Emma already has a lesson at%' then
      rep := rep || E'\nPASS  A10: existing-booking conflict names the student (' || sqlerrm || ')'; npass := npass + 1;
    else rep := rep || E'\nFAIL  A10: unexpected error: ' || sqlerrm; nfail := nfail + 1; end if;
  end;
  select count(*) into n from public.bookings where slot_id = '44444444-4444-4444-4444-444444440098';
  if n = 0 then rep := rep || E'\nPASS  A10b: rejected conflict booked nothing'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A10b: booking leaked through'; nfail := nfail + 1; end if;

  -- A11: a THIRD different student at that same time still books fine
  r := public.book_slots(
       '[{"slot_id":"44444444-4444-4444-4444-444444440098","first_name":"Zoe","last_name":"Test"}]'::jsonb,
       'Parent One', 'vtest-client@example.com', '2045550000', null, tok);
  if json_array_length(r->'bookings') = 1 then
    rep := rep || E'\nPASS  A11: different student unaffected by siblings'' overlaps'; npass := npass + 1;
  else rep := rep || E'\nFAIL  A11: ' || r::text; nfail := nfail + 1; end if;

  -- ==================== B. cancelled_at + display triggers ====================
  -- B1: the trigger stamps the cancellation moment (≈ now)
  update public.bookings set status = 'cancelled'
  where slot_id = '44444444-4444-4444-4444-444444440001';
  select bo.cancelled_at, s.starts_at into b
  from public.bookings bo join public.slots s on s.id = bo.slot_id
  where bo.slot_id = '44444444-4444-4444-4444-444444440001';
  if b.cancelled_at is not null and abs(extract(epoch from (now() - b.cancelled_at))) < 60 then
    rep := rep || E'\nPASS  B1: cancelled_at auto-set to the cancellation moment'; npass := npass + 1;
  else
    rep := rep || E'\nFAIL  B1: cancelled_at=' || coalesce(b.cancelled_at::text, 'null'); nfail := nfail + 1;
  end if;

  -- B1b/B1c: the late-cancel boundary — a lesson 5h out cancels "late",
  -- a lesson 3 days out does not (spec VERIFY item, checked in the DB).
  insert into public.slots (id, pool_id, coach_id, starts_at, duration_min, price, status, created_by) values
    ('44444444-4444-4444-4444-444444440094', v_pool, v_coach, now() + interval '5 hours', 60, 50, 'booked', v_coach),
    ('44444444-4444-4444-4444-444444440095', v_pool, v_coach, now() + interval '3 days',  60, 50, 'booked', v_coach);
  insert into public.bookings (slot_id, student_name, email, phone) values
    ('44444444-4444-4444-4444-444444440094', 'Late Kid', 'vtest-late@example.com', '2045550001'),
    ('44444444-4444-4444-4444-444444440095', 'Fine Kid', 'vtest-fine@example.com', '2045550002');
  update public.bookings set status = 'cancelled'
  where slot_id in ('44444444-4444-4444-4444-444444440094', '44444444-4444-4444-4444-444444440095');
  select (s.starts_at - bo.cancelled_at < interval '24 hours') as is_late into b
  from public.bookings bo join public.slots s on s.id = bo.slot_id
  where bo.slot_id = '44444444-4444-4444-4444-444444440094';
  if b.is_late then rep := rep || E'\nPASS  B1b: cancel 5h before start classifies as late (<24h)'; npass := npass + 1;
  else rep := rep || E'\nFAIL  B1b: 5h-before cancel not classified late'; nfail := nfail + 1; end if;
  select (s.starts_at - bo.cancelled_at < interval '24 hours') as is_late into b
  from public.bookings bo join public.slots s on s.id = bo.slot_id
  where bo.slot_id = '44444444-4444-4444-4444-444444440095';
  if not b.is_late then rep := rep || E'\nPASS  B1c: cancel 3 days before start is NOT late'; npass := npass + 1;
  else rep := rep || E'\nFAIL  B1c: 3d-before cancel wrongly classified late'; nfail := nfail + 1; end if;
  update public.slots set status = 'open' where id = '44444444-4444-4444-4444-444444440001';
  if (select booked_by_display from public.slots where id = '44444444-4444-4444-4444-444444440001') is null then
    rep := rep || E'\nPASS  B2: booked_by_display cleared on reopen'; npass := npass + 1;
  else rep := rep || E'\nFAIL  B2: stale booked_by_display survived reopen'; nfail := nfail + 1; end if;

  -- ==================== C. COACH JWT: admin gates must refuse ====================
  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-2222-2222-222222222222","email":"vtest-coach@example.com","role":"authenticated"}', true);

  if public.is_staff() and not public.is_admin() then
    rep := rep || E'\nPASS  C0: coach claims recognised (staff, not admin)'; npass := npass + 1;
  else rep := rep || E'\nFAIL  C0: is_staff/is_admin wrong for coach'; nfail := nfail + 1; end if;

  begin
    r := public.admin_update_profile(v_coach, 'X', '', true, 'admin');
    rep := rep || E'\nFAIL  C1: coach promoted THEMSELVES via admin_update_profile'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%Only admins%' then rep := rep || E'\nPASS  C1: coach cannot call profile management'; npass := npass + 1;
    else rep := rep || E'\nFAIL  C1: unexpected: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  begin
    r := public.get_revenue_grid(now() - interval '7 days', now() + interval '7 days');
    rep := rep || E'\nFAIL  C2: coach read the revenue grid'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%Only admins%' then rep := rep || E'\nPASS  C2: coach cannot call revenue grid'; npass := npass + 1;
    else rep := rep || E'\nFAIL  C2: unexpected: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  begin
    r := public.reopen_slot('44444444-4444-4444-4444-444444440091');
    rep := rep || E'\nFAIL  C3: coach reopened a slot'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%Only admins%' then rep := rep || E'\nPASS  C3: coach cannot call reopen'; npass := npass + 1;
    else rep := rep || E'\nFAIL  C3: unexpected: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  begin
    r := public.edit_slot('44444444-4444-4444-4444-444444440093',
         now() + interval '5 days', 60, v_pool, v_coach, 50);
    rep := rep || E'\nFAIL  C4: coach edited the ADMIN''s slot'; nfail := nfail + 1;
  exception when others then
    if sqlerrm like '%own slots%' then rep := rep || E'\nPASS  C4: coach cannot edit another coach''s slot'; npass := npass + 1;
    else rep := rep || E'\nFAIL  C4: unexpected: ' || sqlerrm; nfail := nfail + 1; end if;
  end;

  -- RLS checks need the real API role too (definer functions above don't).
  execute 'set local role authenticated';

  -- C5: publishing under another coach's name is blocked by RLS
  begin
    insert into public.slots (pool_id, coach_id, starts_at, duration_min, price, created_by)
    values (v_pool, v_admin, now() + interval '6 days', 60, 50, v_coach);
    rep := rep || E'\nFAIL  C5: coach published a slot under the admin''s name'; nfail := nfail + 1;
  exception when others then
    rep := rep || E'\nPASS  C5: coach cannot publish for another coach'; npass := npass + 1;
  end;

  -- C6: publishing under their OWN name works
  begin
    insert into public.slots (pool_id, coach_id, starts_at, duration_min, price, created_by)
    values (v_pool, v_coach, now() + interval '6 days', 60, 50, v_coach);
    rep := rep || E'\nPASS  C6: coach publishes their own slots'; npass := npass + 1;
  exception when others then
    rep := rep || E'\nFAIL  C6: own-slot publish blocked: ' || sqlerrm; nfail := nfail + 1;
  end;

  -- C7: cancelling the admin's slot silently updates 0 rows
  with u as (update public.slots set status = 'cancelled'
             where id = '44444444-4444-4444-4444-444444440093' returning 1)
  select count(*) into n from u;
  if n = 0 then rep := rep || E'\nPASS  C7: coach cannot cancel another coach''s slot (0 rows)'; npass := npass + 1;
  else rep := rep || E'\nFAIL  C7: coach cancelled the admin''s slot'; nfail := nfail + 1; end if;

  -- C8: role column has no API write grant at all
  begin
    update public.profiles set role = 'admin' where id = v_coach;
    rep := rep || E'\nFAIL  C8: coach wrote profiles.role directly'; nfail := nfail + 1;
  exception when insufficient_privilege then
    rep := rep || E'\nPASS  C8: profiles.role not writable via the API'; npass := npass + 1;
  when others then
    rep := rep || E'\nFAIL  C8: unexpected: ' || sqlerrm; nfail := nfail + 1;
  end;

  execute 'reset role';

  -- ==================== D. ANON: admin RPCs not even executable ====================
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';

  begin
    perform public.get_revenue_grid(now() - interval '7 days', now());
    rep := rep || E'\nFAIL  D1: anon executed get_revenue_grid'; nfail := nfail + 1;
  exception when insufficient_privilege then
    rep := rep || E'\nPASS  D1: anon lacks EXECUTE on get_revenue_grid'; npass := npass + 1;
  when others then rep := rep || E'\nFAIL  D1: unexpected: ' || sqlerrm; nfail := nfail + 1;
  end;
  begin
    perform public.reopen_slot('44444444-4444-4444-4444-444444440091');
    rep := rep || E'\nFAIL  D2: anon executed reopen_slot'; nfail := nfail + 1;
  exception when insufficient_privilege then
    rep := rep || E'\nPASS  D2: anon lacks EXECUTE on reopen_slot'; npass := npass + 1;
  when others then rep := rep || E'\nFAIL  D2: unexpected: ' || sqlerrm; nfail := nfail + 1;
  end;
  begin
    perform public.admin_update_profile(v_coach, 'X', '', true, 'admin');
    rep := rep || E'\nFAIL  D3: anon executed admin_update_profile'; nfail := nfail + 1;
  exception when insufficient_privilege then
    rep := rep || E'\nPASS  D3: anon lacks EXECUTE on admin_update_profile'; npass := npass + 1;
  when others then rep := rep || E'\nFAIL  D3: unexpected: ' || sqlerrm; nfail := nfail + 1;
  end;

  execute 'reset role';

  -- ==================== E. ADMIN JWT: full control + last-admin guard ====================
  perform set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","email":"vtest-admin@example.com","role":"authenticated"}', true);

  if not public.is_admin() then
    rep := rep || E'\nFAIL  E0: admin claims not recognised'; nfail := nfail + 1;
  else
    rep := rep || E'\nPASS  E0: admin claims recognised'; npass := npass + 1;

    -- E1: grid includes the 3 still-confirmed test lessons (3 × $50;
    -- the 4th was cancelled in B). Real bookings may add to the total.
    r := public.get_revenue_grid(now(), now() + interval '7 days');
    select coalesce(sum((c->>'revenue')::numeric), 0) into v
    from json_array_elements(r->'cells') c;
    if v >= 150 then rep := rep || E'\nPASS  E1: revenue grid readable by admin ($' || v || ' ≥ $150 test lessons)'; npass := npass + 1;
    else rep := rep || E'\nFAIL  E1: grid total $' || v || ' (expected ≥ the 3 × $50 test bookings)'; nfail := nfail + 1; end if;

    -- E1b (v7): every cell carries the per-coach breakdown
    if (select bool_and(c->'coaches' is not null and json_array_length(c->'coaches') >= 1)
        from json_array_elements(r->'cells') c) then
      rep := rep || E'\nPASS  E1b: per-coach breakdown present in every cell (v7)'; npass := npass + 1;
    else
      rep := rep || E'\nFAIL  E1b: cells missing the coaches breakdown — has migration_v7.sql been run?'; nfail := nfail + 1;
    end if;

    -- E2: edit another coach's profile + promote/demote round trip
    r := public.admin_update_profile(v_coach, 'VTest Coach Renamed', 'new bio', false, 'admin');
    if (select role from public.profiles where id = v_coach) = 'admin'
       and (select display_name from public.profiles where id = v_coach) = 'VTest Coach Renamed' then
      rep := rep || E'\nPASS  E2: admin edited another profile incl. promotion'; npass := npass + 1;
    else rep := rep || E'\nFAIL  E2: profile not updated'; nfail := nfail + 1; end if;
    r := public.admin_update_profile(v_coach, 'VTest Coach', 'bio', true, 'coach');

    -- E3: last-admin guard — demote every other admin (rolled back with
    -- everything else!), then self-demotion must refuse.
    update public.profiles set role = 'coach' where role = 'admin' and id <> v_admin;
    begin
      r := public.admin_update_profile(v_admin, 'VTest Admin', '', true, 'coach');
      rep := rep || E'\nFAIL  E3: the LAST admin demoted themselves'; nfail := nfail + 1;
    exception when others then
      if sqlerrm like '%last admin%' then rep := rep || E'\nPASS  E3: last-admin demotion blocked'; npass := npass + 1;
      else rep := rep || E'\nFAIL  E3: unexpected: ' || sqlerrm; nfail := nfail + 1; end if;
    end;

    -- E4/E5: reopen a future cancelled slot; refuse a past one
    r := public.reopen_slot('44444444-4444-4444-4444-444444440091');
    if (select status from public.slots where id = '44444444-4444-4444-4444-444444440091') = 'open' then
      rep := rep || E'\nPASS  E4: admin reopened a future cancelled slot'; npass := npass + 1;
    else rep := rep || E'\nFAIL  E4: slot not reopened'; nfail := nfail + 1; end if;
    begin
      r := public.reopen_slot('44444444-4444-4444-4444-444444440092');
      rep := rep || E'\nFAIL  E5: reopened a PAST slot'; nfail := nfail + 1;
    exception when others then
      if sqlerrm like '%in the past%' then rep := rep || E'\nPASS  E5: past slots cannot be reopened'; npass := npass + 1;
      else rep := rep || E'\nFAIL  E5: unexpected: ' || sqlerrm; nfail := nfail + 1; end if;
    end;

    -- E6: admin edits the coach's slot via edit_slot
    r := public.edit_slot('44444444-4444-4444-4444-444444440002',
         now() + interval '2 days', 45, v_pool, v_coach, 60);
    if (r->>'ok')::boolean then rep := rep || E'\nPASS  E6: admin edited a coach''s slot'; npass := npass + 1;
    else rep := rep || E'\nFAIL  E6: ' || r::text; nfail := nfail + 1; end if;

    -- E7: admin publishes a slot for someone else (RLS, as authenticated)
    execute 'set local role authenticated';
    begin
      insert into public.slots (pool_id, coach_id, starts_at, duration_min, price, created_by)
      values (v_pool, v_coach, now() + interval '8 days', 60, 50, v_admin);
      rep := rep || E'\nPASS  E7: admin publishes slots for any coach'; npass := npass + 1;
    exception when others then
      rep := rep || E'\nFAIL  E7: admin blocked from publishing for a coach: ' || sqlerrm; nfail := nfail + 1;
    end;
    execute 'reset role';
  end if;

  -- ==================== report (the exception rolls everything back) ====================
  raise exception using message =
    E'\n\n===== VERIFY_V6 REPORT (this ERROR wrapper is intentional — it forces the rollback of all test data) =====\n' ||
    case when nfail = 0 then 'ALL GREEN' else '*** FAILURES ***' end ||
    ' — ' || npass || ' passed, ' || nfail || ' failed\n' || rep || E'\n\n===== end of report — all test data rolled back =====';
end $$;
