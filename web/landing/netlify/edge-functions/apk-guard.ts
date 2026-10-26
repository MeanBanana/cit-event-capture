// Netlify Edge Function sitting in front of /downloads/*.
//
// The site only shows the Download button on Android phones, and this stops
// people grabbing the APK by its direct link from anything else. We let it
// through only if the browser says Android AND mobile (Client Hints or the
// UA string), everyone else gets a short 403 page explaining why.
//
// Only runs on Netlify, npm run dev/preview just serve the file. UAs are
// trivial to fake, so this is about steering people to the right device,
// not security. It's a public app anyway.
//
// It also checks the on/off switch root controls from the admin console
// (apk_download_enabled() in Supabase). When it's off, everyone gets a
// "paused" page, so the link can't be passed around during a demo. The
// answer is kept for 15 seconds so a busy room doesn't mean one Supabase
// call per tap, and if Supabase can't be reached we let the download through.

// same project and publishable key as web/admin-console/config.js
const SUPABASE_URL = "https://tnydrlxptqegzhbvwpcq.supabase.co";
const SUPABASE_KEY = "sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3";
const SWITCH_TTL_MS = 15_000;
let switchCache: { on: boolean; at: number } | null = null;

async function downloadEnabled(): Promise<boolean> {
  if (switchCache && Date.now() - switchCache.at < SWITCH_TTL_MS) return switchCache.on;
  let on = true;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/apk_download_enabled`, {
      method: "POST",
      headers: { apikey: SUPABASE_KEY, "content-type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(3000),
    });
    if (res.ok) on = (await res.json()) !== false;
  } catch {
    // Supabase unreachable, leave it on
  }
  switchCache = { on, at: Date.now() };
  return on;
}

function page(title: string, body: string) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Argus Shield · ${title}</title>
<style>
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:#070b14;color:#c9ced8;
       font-family:system-ui,-apple-system,"Segoe UI",sans-serif;padding:24px;text-align:center}
  h1{color:#fff;font-size:22px;margin:0 0 10px} p{max-width:420px;line-height:1.5;margin:0 auto 18px}
  a{color:#070b14;background:#ffab40;padding:12px 18px;border-radius:4px;text-decoration:none;font-weight:600}
</style></head>
<body><main>
  <h1>${title}</h1>
  <p>${body}</p>
  <a href="/#download">Back to Argus Shield</a>
</main></body></html>`;
}

const BLOCKED_PAGE = page("Android phones only",
  `The Argus Shield app can only be downloaded on an Android phone. Open this website on your
   Android phone (with "Desktop site" switched off) and tap Download there.`);

const PAUSED_PAGE = page("Downloads are paused",
  "The app download is switched off for the moment. Check back later to get Argus Shield on your Android phone.");

function refuse(html: string) {
  return new Response(html, {
    status: 403,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "vary": "User-Agent, Sec-CH-UA-Mobile, Sec-CH-UA-Platform",
    },
  });
}

export default async (request: Request, context: { next: () => Promise<Response> }) => {
  const ua = request.headers.get("user-agent") ?? "";
  const platform = (request.headers.get("sec-ch-ua-platform") ?? "").replaceAll('"', "");
  const mobileHint = request.headers.get("sec-ch-ua-mobile");

  const android = platform === "Android" || /Android/i.test(ua);
  const mobile = mobileHint === "?1" || /Mobile/i.test(ua);

  if (!(android && mobile)) return refuse(BLOCKED_PAGE);
  if (!(await downloadEnabled())) return refuse(PAUSED_PAGE);
  return context.next();
};

export const config = { path: "/downloads/*" };
