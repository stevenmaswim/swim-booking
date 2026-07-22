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
    auth: { getSession: async () => ({ data: { session: null } }),
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

await browser.close();
server.close();
console.log(`\n${fail === 0 ? "ALL GREEN" : "FAILURES"} — ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
