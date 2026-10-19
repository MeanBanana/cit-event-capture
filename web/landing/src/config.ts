/**
 * The Supabase project the website talks to — the same one as the app and
 * the admin console (web/admin-console/config.js).
 *
 * The publishable key is meant to be public: with it the website can only
 * call submit_contact_message (database rules decide everything else).
 * NEVER put the service_role key here.
 */
export const supabase = {
  url: 'https://tnydrlxptqegzhbvwpcq.supabase.co',
  publishableKey: 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3',
};

/** Saves a contact-form message for the root admin (Messages in the admin console). */
export async function sendContactMessage(m: {name: string; email: string; role: string; organisation: string; message: string}) {
  const res = await fetch(`${supabase.url}/rest/v1/rpc/submit_contact_message`, {
    method: 'POST',
    headers: {apikey: supabase.publishableKey, 'Content-Type': 'application/json'},
    body: JSON.stringify({
      p_name: m.name,
      p_email: m.email,
      p_role: m.role,
      p_organisation: m.organisation || null,
      p_message: m.message || null,
    }),
  });
  if (res.ok) return;
  let reason = '';
  try {
    const body = (await res.json()) as {code?: string; message?: string};
    // our own checks (bad field, too many messages) have readable messages
    if (body.code === '22023' || body.code === '54000') reason = body.message ?? '';
  } catch {
    /* not JSON */
  }
  throw new Error(reason || 'Your message could not be sent. Please check your connection and try again.');
}
