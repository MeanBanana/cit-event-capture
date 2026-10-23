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
