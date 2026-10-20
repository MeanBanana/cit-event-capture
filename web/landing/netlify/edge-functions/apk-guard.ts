// apk-guard.ts — Netlify Edge Function in front of /downloads/*.
//
// The website only shows the Download button on Android phones; this
// stops anyone else fetching the APK directly by its link. It lets the
// request through only when the browser says it is Android AND mobile
// (User-Agent Client Hints, or the user-agent text). Everyone else gets a
// short page explaining why, with status 403.
//
// Runs on Netlify only (npm run dev / preview serve the file directly).
// A user agent can be faked, so this keeps the download for its intended
// devices; it is not a security barrier for a public app.

const BLOCKED_PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Argus Shield · Android phones only</title>
<style>
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:#070b14;color:#c9ced8;
       font-family:system-ui,-apple-system,"Segoe UI",sans-serif;padding:24px;text-align:center}
  h1{color:#fff;font-size:22px;margin:0 0 10px} p{max-width:420px;line-height:1.5;margin:0 auto 18px}
  a{color:#070b14;background:#ffab40;padding:12px 18px;border-radius:4px;text-decoration:none;font-weight:600}
</style></head>
<body><main>
  <h1>Android phones only</h1>
  <p>The Argus Shield app can only be downloaded on an Android phone. Open this website on your
     Android phone (with "Desktop site" switched off) and tap Download there.</p>
  <a href="/#download">Back to Argus Shield</a>
</main></body></html>`;

export default async (request: Request, context: { next: () => Promise<Response> }) => {
  const ua = request.headers.get("user-agent") ?? "";
  const platform = (request.headers.get("sec-ch-ua-platform") ?? "").replaceAll('"', "");
  const mobileHint = request.headers.get("sec-ch-ua-mobile");

  const android = platform === "Android" || /Android/i.test(ua);
  const mobile = mobileHint === "?1" || /Mobile/i.test(ua);

  if (android && mobile) {
    return context.next();
  }
  return new Response(BLOCKED_PAGE, {
    status: 403,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "vary": "User-Agent, Sec-CH-UA-Mobile, Sec-CH-UA-Platform",
    },
  });
};

export const config = { path: "/downloads/*" };
