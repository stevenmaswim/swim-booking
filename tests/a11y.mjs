// axe-core audit of the built pages (serious/critical must be zero).
import { createServer } from "http";
import { readFile, stat } from "fs/promises";
import { join, extname } from "path";
import { fileURLToPath } from "url";
import puppeteer from "puppeteer-core";

const ROOT = fileURLToPath(new URL("../dist", import.meta.url));
const AXE = await readFile(new URL("../node_modules/axe-core/axe.min.js", import.meta.url), "utf8");
const CHROME =
  process.env.CHROME_PATH ??
  "/Users/stovecm/Library/Caches/ms-playwright/chromium_headless_shell-1223/chrome-headless-shell-mac-arm64/chrome-headless-shell";
const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".jpg": "image/jpeg", ".png": "image/png", ".woff2": "font/woff2" };

const server = createServer(async (req, res) => {
  try {
    let p = join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname));
    try { if ((await stat(p)).isDirectory()) p = join(p, "index.html"); } catch { if (!extname(p)) p += ".html"; }
    const body = await readFile(p);   // read BEFORE writing headers
    res.writeHead(200, { "Content-Type": MIME[extname(p)] ?? "application/octet-stream" });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise((r) => server.listen(8896, "127.0.0.1", r));

const MOCK = `
  window.supabase = { createClient: () => ({
    from: () => { const b = { select(){return b}, eq(){return b}, neq(){return b}, in(){return b}, gte(){return b}, lt(){return b}, lte(){return b}, order(){return b}, limit(){return b}, maybeSingle(){return Promise.resolve({data:null,error:null})}, then(r){ r({data: [], error: null}); } }; return b; },
    rpc: () => Promise.resolve({ data: null, error: null }),
    functions: { invoke: () => Promise.resolve({ data: {}, error: null }) },
    auth: { getSession: async () => ({ data: { session: null } }) },
  }) };`;
const CONF = `const BUSINESS_TIMEZONE='America/Chicago'; function showFatalError(m){} let db = window.supabase.createClient('x','y');`;

const browser = await puppeteer.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
const page = await browser.newPage();
await page.setRequestInterception(true);
page.on("request", (req) => {
  const u = req.url();
  if (u.includes("supabase-js")) return req.respond({ contentType: "text/javascript", body: MOCK });
  if (u.includes("chart.js")) return req.respond({ contentType: "text/javascript", body: "window.Chart=undefined;" });
  if (u.endsWith("/config.js")) return req.respond({ contentType: "text/javascript", body: CONF });
  if (!u.startsWith("http://127.0.0.1:8896")) return req.respond({ status: 204, body: "" });
  req.continue();
});

let worst = 0;
async function audit(label, url, prep) {
  await page.goto(url, { waitUntil: "networkidle0" });
  if (prep) await page.evaluate(prep);
  await page.evaluate(AXE);
  const res = await page.evaluate(async () => await axe.run(document, { resultTypes: ["violations"] }));
  const sev = { minor: 1, moderate: 2, serious: 3, critical: 4 };
  console.log(`\n=== ${label} — ${res.violations.length} violation types ===`);
  for (const v of res.violations) {
    worst = Math.max(worst, sev[v.impact] ?? 0);
    console.log(`[${v.impact}] ${v.id}: ${v.help} (${v.nodes.length} nodes)`);
    for (const n of v.nodes.slice(0, 3)) console.log("   ", n.target.join(" "));
  }
}

await audit("book.html", "http://127.0.0.1:8896/book.html");
await audit("mybookings.html", "http://127.0.0.1:8896/mybookings.html");
await audit("staff.html (login)", "http://127.0.0.1:8896/staff.html");
await audit("staff.html (dashboard chrome)", "http://127.0.0.1:8896/staff.html", () => {
  document.getElementById("loginView").style.display = "none";
  document.getElementById("dashView").style.display = "block";
});
await audit("homepage", "http://127.0.0.1:8896/");

await browser.close(); server.close();
console.log(worst >= 2 ? "\nRESULT: violations above minor — FIX NEEDED" : "\nRESULT: OK (nothing above minor)");
process.exit(worst >= 2 ? 1 : 0);
