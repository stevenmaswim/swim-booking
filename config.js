// Fill these in from Supabase Dashboard > Project Settings > API
// The anon key is SAFE to expose publicly — security is enforced by
// Row Level Security in the database, not by hiding this key.
const SUPABASE_URL = "https://jvzahjtoiwfsshgzsyym.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp2emFoanRvaXdmc3NoZ3pzeXltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0NDk5MzQsImV4cCI6MjA5OTAyNTkzNH0.k3vxFwCAKRcMZgViFHV-KnV1AFDxzeAzFxLjAFThcPI";

// The pool's local timezone (IANA name). Lesson times on record surfaces —
// the CSV export and the "My Bookings" list — are formatted in this zone so
// they always show the clock time at the pool and match the confirmation
// emails, no matter where the viewer's device is set. Keep this in sync with
// the BUSINESS_TIMEZONE secret on the emails Edge Function. If the school
// ever moves, change it here (and in the Edge Function secret).
const BUSINESS_TIMEZONE = "America/Chicago";

// Shows a persistent red banner at the top of the page so configuration
// or connection problems are always visible — never a silent blank page.
function showFatalError(message) {
  let el = document.getElementById('fatalError');
  if (!el) {
    el = document.createElement('div');
    el.id = 'fatalError';
    el.style.cssText = 'background:#fee2e2;color:#991b1b;padding:14px 20px;' +
      'font-size:0.95rem;font-weight:600;text-align:center;position:sticky;top:0;z-index:200;';
    document.body.prepend(el);
  }
  el.textContent = '⚠️ ' + message;
}

// db is null when Supabase can't be initialized — every page checks this
// before querying and shows a visible error instead of failing silently.
let db = null;
if (typeof supabase === 'undefined') {
  showFatalError('Could not load the Supabase library. Check your internet connection and reload.');
} else if (!/^https:\/\//.test(SUPABASE_URL) || SUPABASE_ANON_KEY.indexOf('YOUR_') === 0) {
  showFatalError('This site is not configured yet: open config.js and set SUPABASE_URL and SUPABASE_ANON_KEY (Supabase Dashboard > Project Settings > API).');
} else {
  try {
    db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  } catch (e) {
    showFatalError('Supabase failed to initialize: ' + e.message + ' — check the values in config.js.');
  }
}
