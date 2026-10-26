/**
 * Is the APK download switched on? Root flips this in the admin console
 * (we're on free Supabase, so it goes off when we demo to a big room).
 *
 * Same Supabase project and publishable key as web/admin-console/config.js,
 * fine to have in public. netlify/edge-functions/apk-guard.ts does the same
 * check for the file itself.
 *
 * If Supabase can't be reached we leave the download on. The APK is served
 * by Netlify, so a hiccup on our side shouldn't take the button away.
 */
const SUPABASE_URL = 'https://tnydrlxptqegzhbvwpcq.supabase.co';
const SUPABASE_KEY = 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3';

export async function apkDownloadEnabled(signal?: AbortSignal): Promise<boolean> {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/apk_download_enabled`, {
      method: 'POST',
      headers: {apikey: SUPABASE_KEY, 'content-type': 'application/json'},
      body: '{}',
      signal,
    });
    if (!res.ok) return true;
    return (await res.json()) !== false;
  } catch {
    return true;
  }
}
