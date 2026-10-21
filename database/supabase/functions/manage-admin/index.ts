// manage-admin — Supabase Edge Function
//
// Called by the web admin console's "Remove" on a station admin
// (web/admin-console). Only the ROOT admin may.
//
//   { action: "delete", userid }
//       Removes the account (database function remove_admin_account):
//         'deleted'    nothing they did is on record -> rows + login deleted
//         'anonymised' they worked on submissions / cases -> their work stays
//                      in the records as "Former admin", and the login is
//                      blocked for good and moved to a placeholder email
//       Either way the activity log gets a DEL line ("Admin removed: ...").
//       The root admin itself can't be removed.
//
// Why here and not in the browser: deleting or blocking someone else's login
// needs the service key, which must never be in a web page.
//
// Deploy (from the database/ folder):
//   supabase functions deploy manage-admin
// verify_jwt is off in config.toml because this function checks the caller
// itself (logged in AND root admin), like create-admin.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** JSON response. Errors are always { error: "message for the admin" }. */
function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const fail = (status: number, message: string) =>
  reply(status, { error: message });

/** Trimmed string, or "" for anything that isn't a string. */
const text = (value: unknown) => (typeof value === "string" ? value.trim() : "");

/** A long random password for a blocked login (nobody ever uses it). */
function randomPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("") + "Aa1";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "Use POST.");

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return fail(500, "The server is not set up correctly (missing keys).");
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- Who is calling? Must be the root admin. ------------------------------
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return fail(401, "Please sign in again.");
  const { data: auth, error: authError } = await admin.auth.getUser(token);
  if (authError || !auth?.user) return fail(401, "Please sign in again.");
  const { data: caller, error: callerError } = await admin
    .from("User")
    .select("userid, role")
    .eq("authid", auth.user.id)
    .maybeSingle();
  if (callerError) return fail(500, "Could not check your account. Try again.");
  const { data: callerAdmin, error: adminError } = caller?.role === "admin"
    ? await admin.from("admin").select("admin_type").eq("userid", caller.userid).maybeSingle()
    : { data: null, error: null };
  if (adminError) return fail(500, "Could not check your account. Try again.");
  if (!caller || callerAdmin?.admin_type !== "root") {
    return fail(403, "Only the root administrator can remove admin accounts.");
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "The request could not be read.");
  }
  const action = text(body.action);
  const userid = typeof body.userid === "number" ? body.userid : Number(body.userid);
  if (!Number.isInteger(userid) || userid <= 0) return fail(400, "Which admin?");
  if (action !== "delete") return fail(400, "Unknown action.");

  // =========================================================================
  // The database checks the target is a station admin (not the root admin).
  const { data: removed, error: removeError } = await admin.rpc(
    "remove_admin_account",
    { p_userid: userid, p_removed_by: caller.userid },
  );
  if (removeError || !removed) {
    if (removeError?.code === "P0002" || removeError?.code === "42501") {
      return fail(removeError.code === "P0002" ? 404 : 403, removeError.message);
    }
    console.error("remove_admin_account failed", removeError);
    return fail(500, "The account could not be removed. Try again.");
  }
  const { mode, authid, email } = removed as { mode: string; authid: string; email?: string };
  if (mode === "deleted") {
    const { error } = await admin.auth.admin.deleteUser(authid);
    if (error) console.error("deleteUser failed (the account rows are gone)", error);
  } else {
    // Their work stays on record, so the login can't be deleted; block it
    // for good and free the real email address.
    const { error } = await admin.auth.admin.updateUserById(authid, {
      email,
      email_confirm: true,
      password: randomPassword(),
      ban_duration: "876000h", // ~100 years
      user_metadata: {},
    });
    if (error) {
      console.error("Could not block the login", error);
      return fail(500, "The account was removed, but its sign-in could not be blocked. " +
        "Delete it in Supabase under Authentication → Users.");
    }
  }
  return reply(200, { mode });
});
