// Post-build smoke test: serves dist/ and drives the real pages in headless
// Chromium with a mocked Supabase client (CDN + config.js intercepted), so it
// runs with no network and no live backend.
//
//   pnpm build && node tests/smoke.mjs
//
// Requires puppeteer-core + a Chrome/Chromium binary; set CHROME_PATH or rely
// on the default macOS Playwright cache path below.
import { createServer } from "http";
import { readFile, stat } from "fs/promises";
import { join, extname, dirname } from "path";
import { fileURLToPath } from "url";
import puppeteer from "puppeteer-core";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "dist");
const CHROME =
  process.env.CHROME_PATH ??
  "/Users/stovecm/Library/Caches/ms-playwright/chromium_headless_shell-1223/chrome-headless-shell-mac-arm64/chrome-headless-shell";
const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".png": "image/png", ".xml": "text/xml", ".txt": "text/plain" };

let pass = 0, fail = 0;
const check = (label, cond, detail) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${cond ? "" : "  → " + (detail ?? "")}`);
  cond ? pass++ : fail++;
};

// ---- tiny static server over dist/ ----
const server = createServer(async (req, res) => {
  try {
    let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    let file = join(ROOT, p);
    try { if ((await stat(file)).isDirectory()) file = join(file, "index.html"); }
    catch { if (!extname(file)) file = file + ".html"; }
    const body = await readFile(file);
    res.writeHead(200, { "Content-Type": MIME[extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch { res.writeHead(404); res.end("not found"); }
});
await new Promise((r) => server.listen(8898, "127.0.0.1", r));
const BASE = "http://127.0.0.1:8898";

// ---- mock supabase-js + config.js, injected via request interception ----
const MOCK_SUPABASE = `
  window.__rpcCalls = []; window.__invokes = [];
  function __builder(table) {
    const b = {
      select(){return b}, eq(){return b}, neq(){return b}, in(){return b},
      gte(){return b}, lt(){return b}, lte(){return b}, order(){return b},
      limit(){return b}, insert(){return b}, update(){return b},
      maybeSingle(){b._s=1;return b}, single(){b._s=1;return b},
      then(res){ let rows=(window.__fixtures||{})[table]||[];
        res({ data: b._s ? (rows[0] ?? null) : rows, error: null }); }
    };
    return b;
  }
  window.supabase = { createClient: () => ({
    from: __builder,
    rpc: (name, args) => { window.__rpcCalls.push({name, args});
      const h=(window.__rpcHandlers||{})[name];
      return Promise.resolve(h ? h(args) : { data: null, error: null }); },
    functions: { invoke: (name, opts) => { window.__invokes.push({name, body: opts?.body});
      return Promise.resolve({ data: { ok: true }, error: null }); } },
    auth: { getSession: async () => ({ data: { session: window.__session ?? null } }),
      signOut: async () => ({}), signInWithOAuth: async () => ({ error: null }) },
    storage: { from: () => ({}) },
  }) };
`;
const MOCK_CONFIG = `
  const BUSINESS_TIMEZONE = 'America/Chicago';   // real config.js defines this too
  function showFatalError(m){ console.error('FATAL', m); }
  let db = window.supabase.createClient('http://mock', 'anon');
`;

const browser = await puppeteer.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
const page = await browser.newPage();
const consoleErrors = [];
page.on("pageerror", (e) => consoleErrors.push(String(e)));
page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });
await page.setRequestInterception(true);
page.on("request", (req) => {
  const url = req.url();
  if (url.includes("cdn.jsdelivr.net/npm/@supabase/supabase-js"))
    return req.respond({ contentType: "text/javascript", body: MOCK_SUPABASE });
  if (url.includes("cdn.jsdelivr.net/npm/chart.js"))
    return req.respond({ contentType: "text/javascript", body: "window.Chart=undefined;" });
  if (url.endsWith("/config.js"))
    return req.respond({ contentType: "text/javascript", body: MOCK_CONFIG });
  if (!url.startsWith(BASE)) return req.respond({ status: 204, body: "" }); // no other network
  req.continue();
});
await page.evaluateOnNewDocument(() => {
  window.__fixtures = {
    profiles: [{ display_name: "Coach A", bio: "Loves teaching", photo_url: null, is_public: true }],
    pools: [{ name: "Main Pool", address: "1 Pool St", notes: "", photo_url: null, active: true }],
    slots: [],
  };
});

// ---- 1. homepage: brand, sections, Supabase-fed grids, no demo text ----
await page.goto(`${BASE}/`, { waitUntil: "networkidle0" });
const home = await page.content();
check("home: KSJ branding present", home.includes("KSJ Swimming"));
check("home: hero headline", home.includes("Learn to swim with confidence"));
check("home: no Astroship/Web3Templates/lorem text",
  !/astroship|web3templates|lorem ipsum/i.test(await page.evaluate(() => document.body.innerText)));
check("home: Book a Lesson CTA points at /book.html",
  await page.$$eval('a[href="/book.html"]', (a) => a.length) >= 2);
await page.waitForFunction(() => document.querySelectorAll("#coachGrid h3").length > 0);
check("home: coaches load from (mock) Supabase",
  (await page.$eval("#coachGrid", (e) => e.textContent)).includes("Coach A"));
check("home: locations load from (mock) Supabase",
  (await page.$eval("#poolGrid", (e) => e.textContent)).includes("Main Pool"));
check("home: coaches/locations anchors exist",
  await page.evaluate(() => !!document.getElementById("coaches") && !!document.getElementById("locations")));

// every internal link on the homepage resolves in dist/
const links = await page.$$eval("a[href]", (as) =>
  as.map((a) => a.getAttribute("href")).filter((h) => h.startsWith("/") && !h.startsWith("//")));
const badLinks = [];
for (const href of [...new Set(links)]) {
  const res = await fetch(BASE + href.split("#")[0]).catch(() => null);
  if (!res || res.status !== 200) badLinks.push(href);
}
check("home: every internal link resolves", badLinks.length === 0, JSON.stringify(badLinks));

// ---- 2. contact page ----
await page.goto(`${BASE}/contact`, { waitUntil: "networkidle0" });
check("contact: mailto present",
  (await page.content()).includes("mailto:ksjswimming@gmail.com"));

// ---- 3. booking pages served untouched from public/, boot without errors ----
consoleErrors.length = 0;
await page.goto(`${BASE}/book.html`, { waitUntil: "networkidle0" });
check("book.html: booking calendar boots (week label rendered)",
  (await page.$eval("#weekLabel", (e) => e.textContent)).length > 0);
check("book.html: Supabase client initialised (no fatal banner)",
  await page.evaluate(() => !document.getElementById("fatalError")));

await page.goto(`${BASE}/mybookings.html`, { waitUntil: "networkidle0" });
check("mybookings.html: OTP entry present",
  await page.evaluate(() => !!document.getElementById("mbEmail")));

await page.goto(`${BASE}/staff.html`, { waitUntil: "networkidle0" });
check("staff.html: login view shown (no session)",
  await page.$eval("#loginView", (e) => e.style.display !== "none"));

check("no console/page errors across all pages", consoleErrors.length === 0,
  JSON.stringify(consoleErrors.slice(0, 3)));

// ---- 4. staff DASHBOARD (mock admin session): rain-out feature ----
await page.evaluateOnNewDocument(() => {
  const at = (h, dayOffset = 0) => {
    const d = new Date(); d.setDate(d.getDate() + dayOffset); d.setHours(h, 0, 0, 0);
    return d.toISOString();
  };
  window.__session = { user: { id: "admin-1", email: "admin@x.com" } };
  window.__rpcHandlers = {
    is_staff: () => ({ data: true, error: null }),
    is_admin: () => ({ data: true, error: null }),
  };
  window.__fixtures = {
    profiles: [
      { id: "admin-1", display_name: "Admin A", bio: "", is_public: true, role: "admin", photo_url: null,
        notify_cancellations: true, notify_unassigned_cancellations: true,
        cancellations_seen_at: new Date(Date.now() - 3 * 864e5).toISOString() },
      { id: "co1", display_name: "Coach B", bio: "", is_public: true, role: "coach", photo_url: null,
        notify_cancellations: true, notify_unassigned_cancellations: true, cancellations_seen_at: null },
    ],
    pools: [{ id: "p1", name: "Main Pool", address: "1 Pool St", notes: "", active: true, photo_url: null }],
    settings: [{ default_price: 50 }],
    slots: [
      { id: "so", starts_at: at(9),  duration_min: 60, status: "open",       pool_id: "p1", coach_id: "co1", rained_out_at: null, pools: { name: "Main Pool", address: "1 Pool St" }, profiles: { display_name: "Coach B" }, bookings: [] },
      { id: "sb", starts_at: at(11), duration_min: 60, status: "booked",     pool_id: "p1", coach_id: "co1", rained_out_at: null, pools: { name: "Main Pool", address: "1 Pool St" }, profiles: { display_name: "Coach B" }, bookings: [{ first_name: "Kid", last_name: "One", email: "k@x.com", phone: "1", parent_name: "P", created_at: at(8), status: "confirmed" }] },
      { id: "sr", starts_at: at(15), duration_min: 60, status: "rained_out", pool_id: "p1", coach_id: "co1", rained_out_at: at(8), pools: { name: "Main Pool", address: "1 Pool St" }, profiles: { display_name: "Coach B" }, bookings: [{ first_name: "Wet", last_name: "Kid", email: "w@x.com", phone: "1", parent_name: "P", created_at: at(7), status: "rained_out" }] },
      // definitively FUTURE rained slot: "Undo rain-out" is future-only by
      // design, so this keeps that assertion independent of the clock.
      { id: "sr2", starts_at: at(15, 1), duration_min: 60, status: "rained_out", pool_id: "p1", coach_id: "co1", rained_out_at: at(8), pools: { name: "Main Pool", address: "1 Pool St" }, profiles: { display_name: "Coach B" }, bookings: [] },
    ],
    bookings: [
      { client_id: "c1", status: "confirmed",  slots: { starts_at: at(11) } },
      { client_id: "c1", status: "cancelled",  cancelled_at: at(6), slots: { starts_at: at(11) } },
      { client_id: "c1", status: "rained_out", cancelled_at: null,  slots: { starts_at: at(15) } },
    ],
    clients: [{ id: "c1", name: "Kid One", email: "k@x.com", phone: "1", notes: "", parent_name: "P", created_at: at(1, -30) }],
  };
});
await page.goto(`${BASE}/staff.html`, { waitUntil: "networkidle0" });
await page.waitForFunction(() => document.getElementById("dashView").style.display === "block");
check("staff dash: boots with mock admin session",
  (await page.$eval("#whoami", (e) => e.textContent)).includes("Admin A"));
check("staff dash: rained slot renders distinctly on the calendar",
  await page.evaluate(() => {
    const el = document.querySelector('.cal-block.slot-rained[data-slot-id="sr"]');
    return !!el && el.textContent.includes("Rained out");
  }));
await page.waitForFunction(() => document.querySelectorAll("#slotAdminList tr").length > 1);
const slotAdmin = await page.evaluate(() => ({
  rain: document.querySelectorAll("#slotAdminList [data-rain]").length,
  undo: document.querySelectorAll('#slotAdminList [data-undorain="sr2"]').length,
}));
check("staff dash: upcoming table has Rain out on open/booked + Undo on a future rained slot",
  slotAdmin.rain === 2 && slotAdmin.undo === 1, JSON.stringify(slotAdmin));

// bulk flow: dry-run preview, then confirm → one deduped email invoke
await page.evaluate(() => {
  window.__rpcHandlers.rain_out_day = (args) => args.p_dry_run
    ? { data: { dry_run: true, open: 1, booked: 1 }, error: null }
    : { data: { dry_run: false, open: 1, booked: 1, booking_ids: ["bk-1", "bk-2"] }, error: null };
});
await page.click("#rainDayBtn");
await page.waitForSelector("#rainModal.show");
await page.click("#rnGo"); // dry run
await page.waitForFunction(() => document.getElementById("rnGo").textContent === "Confirm rain-out");
check("staff dash: dry-run preview shows impact before confirming",
  (await page.$eval("#rnMsg", (e) => e.textContent)).includes("1 booked and 1 open"));
await page.click("#rnGo"); // confirm
await page.waitForFunction(() => !document.getElementById("rainModal").classList.contains("show"));
const rainCalls = await page.evaluate(() => window.__rpcCalls.filter((c) => c.name === "rain_out_day"));
check("staff dash: rain_out_day called dry-run first, then for real, with the tz",
  rainCalls.length === 2 && rainCalls[0].args.p_dry_run === true &&
  rainCalls[1].args.p_dry_run === false && rainCalls[1].args.p_tz === "America/Chicago",
  JSON.stringify(rainCalls.map((c) => c.args)));
check("staff dash: whole-day bulk sends null time window",
  rainCalls[1].args.p_from_time === null && rainCalls[1].args.p_to_time === null);

// v10: a PARTIAL day — set "From 12:00" and dry-run again
await page.click("#rainDayBtn");
await page.waitForSelector("#rainModal.show");
await page.evaluate(() => { document.getElementById("rnFrom").value = "12:00"; });
await page.click("#rnGo");
await page.waitForFunction(() =>
  window.__rpcCalls.filter((c) => c.name === "rain_out_day").length >= 3);
check("staff dash: afternoon-only window passes p_from_time to the RPC",
  await page.evaluate(() => {
    const c = window.__rpcCalls.filter((x) => x.name === "rain_out_day").pop();
    return c.args.p_from_time === "12:00" && c.args.p_to_time === null && c.args.p_dry_run === true;
  }));
await page.click("#rnCancel");
check("staff dash: ONE rain_out email invoke carrying all booking ids (dedupe server-side)",
  await page.evaluate(() => {
    const inv = window.__invokes.filter((i) => i.body && i.body.type === "rain_out");
    return inv.length === 1 && inv[0].body.booking_ids.length === 2;
  }));

// clients: rained lesson is NOT a cancellation
await page.evaluate(() => {
  document.querySelector('[data-tab="clients"]').click();
});
check("staff dash: client stats count 1 lesson, 1 cancelled — rained_out excluded",
  await page.evaluate(() => {
    const cells = [...document.querySelectorAll("#clientsList td")].map((t) => t.textContent);
    return cells.includes("1") && !cells.includes("2");
  }),
  await page.$eval("#clientsList", (e) => e.textContent));

// revenue: rained summary lines
await page.evaluate(() => {
  window.__rpcHandlers.get_revenue_report = () => ({ data: {
    total_lessons: 3, total_revenue: 150, rained_lessons: 2, rained_revenue: 100,
    years: [], by_period: [], by_coach: [], by_pool: [] }, error: null });
  window.__rpcHandlers.get_revenue_grid = () => ({ data: {
    cells: [{ dow: 3, hour: 16, lessons: 3, revenue: 150, coaches: [{ coach: "Coach B", lessons: 3, revenue: 150 }] }],
    rained: { lessons: 2, revenue: 100 } }, error: null });
  document.querySelector('[data-tab="revenue"]').click();
});
await page.waitForFunction(() => !!document.getElementById("rgRainedLine"));
check("staff dash: revenue grid shows the weather-impact line",
  (await page.$eval("#rgRainedLine", (e) => e.textContent)).includes("2 lessons ($100.00 not realized)"));
check("staff dash: totals line reports rained-out impact",
  (await page.$eval("#revTotals", (e) => e.textContent)).includes("Rained out: 2 lessons"));

// week CSV: rained row exported as RAINED OUT
await page.evaluate(() => {
  document.querySelector('[data-tab="calendar"]').click();
  window.__csv = null;
  window.downloadCsv = (name, text) => { window.__csv = { name, text }; };
});
await page.click("#weekExport");
await page.waitForFunction(() => window.__csv);
check("staff dash: week CSV labels the rained slot RAINED OUT",
  await page.evaluate(() => window.__csv.text.includes('"RAINED OUT"')));

// ---- 5. Recently Cancelled panel (v11) ----
await page.evaluate(() => {
  const ago = (h) => new Date(Date.now() - h * 3600e3).toISOString();
  const soon = (h) => new Date(Date.now() + h * 3600e3).toISOString();
  // The RPC is the server-side gate: it only ever returns client
  // cancellations, so staff-cancelled and rained-out rows simply aren't here.
  window.__rpcHandlers.get_recent_cancellations = (args) => {
    const rows = [
      { id: "cx1", cancelled_at: ago(1), student_name: "Emma Lee", first_name: "Emma",
        email: "emma@x.com", phone: "204-555-1111", slot_id: "sl-open", starts_at: soon(30),
        duration_min: 60, slot_status: "open", coach_id: "co1", pool_name: "Canyon Creek",
        coach: "Coach B", seconds_before: 30 * 3600 },
      { id: "cx2", cancelled_at: ago(50), student_name: "Liam Ray", first_name: "Liam",
        email: "liam@x.com", phone: null, slot_id: "sl-rebooked", starts_at: soon(80),
        duration_min: 60, slot_status: "booked", coach_id: "co1", pool_name: "Main Pool",
        coach: "Coach B", seconds_before: 5 * 3600 },
    ];
    return { data: { cancellations: args.p_only_open ? rows.filter((r) => r.slot_status === "open") : rows }, error: null };
  };
});
await page.evaluate(() => { document.querySelector('[data-tab="bookings"]').click(); });
await page.waitForFunction(() => document.querySelectorAll("#cxList tr").length > 1);
const cxHtml = await page.$eval("#cxList", (e) => e.innerHTML);
check("cx: client cancellation shows as reopened & still available",
  cxHtml.includes("Reopened &amp; still available") && cxHtml.includes("Emma"));
check("cx: a slot taken by someone else reads Rebooked",
  cxHtml.includes("Rebooked by someone else"));
check("cx: <24h notice reuses the late-cancel badge, longer notice does not",
  cxHtml.includes("Cancelled &lt;24h — 5h before") && cxHtml.includes("30h before"));
check("cx: only the coach's own filter + only-open reach the RPC",
  await page.evaluate(() => {
    const c = window.__rpcCalls.filter((x) => x.name === "get_recent_cancellations").pop();
    return c.args.p_days === 14 && "p_coach_id" in c.args && "p_only_open" in c.args;
  }));

// "only slots still open" filter drops the rebooked row
await page.evaluate(() => { document.getElementById("cxOnlyOpen").checked = true; document.getElementById("cxOnlyOpen").onchange(); });
await page.waitForFunction(() => !document.getElementById("cxList").innerHTML.includes("Rebooked"));
check("cx: only-open filter hides rebooked slots",
  !(await page.$eval("#cxList", (e) => e.innerHTML)).includes("Rebooked by someone else"));

// unread badge: coach's seen_at is null → both rows unread; viewing clears it
await page.evaluate(() => { document.getElementById("cxOnlyOpen").checked = false; document.getElementById("cxOnlyOpen").onchange(); });
await page.waitForFunction(() => document.querySelectorAll("#cxList tr").length > 2);
check("cx: unread badge counts cancellations newer than last-viewed",
  await page.evaluate(() => {
    myProfile.cancellations_seen_at = new Date(Date.now() - 2 * 3600e3).toISOString();
    renderCxBadge();
    const el = document.getElementById("cxBadge");
    return el.style.display !== "none" && el.textContent === "1 new";
  }));
check("cx: viewing the panel clears the badge and stamps the profile server-side",
  await page.evaluate(async () => {
    await markCancellationsSeen();
    const el = document.getElementById("cxBadge");
    return el.style.display === "none" && !!myProfile.cancellations_seen_at;
  }));

// profile toggles present, default ON, admin-only one visible for admins
await page.evaluate(() => { document.querySelector('[data-tab="me"]').click(); });
check("cx: coach notification toggle defaults ON",
  await page.$eval("#meNotifyCx", (e) => e.checked));
check("cx: admin-only unassigned toggle visible for an admin",
  await page.$eval("#meNotifyUnassignedWrap", (e) => e.style.display !== "none"));

// ---- 6. the cancel path fires exactly one alert invoke ----
await page.goto(`${BASE}/mybookings.html`, { waitUntil: "networkidle0" });
await page.evaluate(() => {
  window.__rpcHandlers.cancel_booking = () => ({ data: { cancelled: true, booking_id: "bk-9", starts_at: new Date().toISOString() }, error: null });
  window.__rpcHandlers.verify_and_list_bookings = () => ({ data: { bookings: [] }, error: null });
  window.confirm = () => true;
  renderBookings([{ status: "confirmed", starts_at: new Date(Date.now() + 864e5).toISOString(),
    duration_min: 60, first_name: "Kid", pool_name: "Main Pool", cancel_token: "tok-9" }]);
});
await page.click("#upcomingList [data-cancel]");
await page.waitForFunction(() => window.__invokes.some((i) => i.body && i.body.type === "cancellation_alert"));
check("cx: a CLIENT cancellation fires exactly one cancellation_alert with the booking id",
  await page.evaluate(() => {
    const a = window.__invokes.filter((i) => i.body && i.body.type === "cancellation_alert");
    return a.length === 1 && a[0].body.booking_id === "bk-9";
  }));

// mybookings: distinct rained badge for clients
await page.goto(`${BASE}/mybookings.html`, { waitUntil: "networkidle0" });
await page.evaluate(() => {
  renderBookings([
    { status: "rained_out", starts_at: new Date(Date.now() - 3600e3).toISOString(), duration_min: 60, first_name: "Kid", pool_name: "Main Pool", cancel_token: "t1" },
    { status: "cancelled",  starts_at: new Date(Date.now() - 7200e3).toISOString(), duration_min: 60, first_name: "Kid", pool_name: "Main Pool", cancel_token: "t2" },
  ]);
});
check("mybookings: rained-out badge distinct from cancelled",
  await page.evaluate(() => {
    const t = document.getElementById("pastList").innerHTML;
    return t.includes('badge rained">rained out') && t.includes('badge cancelled">cancelled');
  }));

await browser.close();
server.close();
console.log(`\n${fail === 0 ? "ALL GREEN" : "FAILURES"} — ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
