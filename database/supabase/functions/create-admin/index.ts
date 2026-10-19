// create-admin — Supabase Edge Function
//
// Called by the web admin console's "New admin" form (web/admin-console).
// Creates the login of a police station's admin. Only the ROOT admin may.
//
// Why this runs here and not in the browser:
//   Creating someone else's account with the 'admin' role needs the service
//   key, which can do anything in the project. That key must never be in a
//   web page, so the console calls this function and the key stays on
//   Supabase's servers (as an environment variable).
//
// What it does:
//   1. Checks the caller is logged in AND is the root admin (admin table).
//   2. Validates the form values.
//   3. Checks the username isn't taken (clear message).
//   4. auth.admin.createUser with role 'admin' in app_metadata (only the
//      service key can set that) and no password. The sign-up triggers
//      create the "User" row and the admin row (always 'normal', station
//      from user_metadata.admin_station).
//   5. Makes sure the rows are right (see create-investigator for why).
//   6. Emails the new admin a link to choose their password, then returns
//      { userid, email, email_sent }.
//
// The link opens web/admin-console/set-password.html (PASSWORD_SETUP_URL
// secret). After that the new admin signs in to the mobile app with their
// username and the password they chose.
//
// Deploy (from the database/ folder):
//   supabase functions deploy create-admin
// verify_jwt is off in config.toml because this function checks the caller
// itself (step 1).

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

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

// Same rules as the console and the database.
const USERNAME = /^[A-Za-z0-9_.]{3,30}$/; // "User"_username_format check
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LOCAL_PHONE = /^\d{9}$/; // the 9 digits after +27

/**
 * Emails [email] a link to choose their password (Supabase's "Reset
 * password" email). The link opens the set-password page of the web admin
 * console (PASSWORD_SETUP_URL secret), which works on any device; the
 * mobile app's own reset links only open on the phone that asked for them.
 * Returns false if the email could not be sent (e.g. the hourly email
 * limit); the account is kept and the person can use "Forgot password?".
 */
async function sendPasswordSetup(
  admin: SupabaseClient,
  email: string,
): Promise<boolean> {
  const redirectTo = Deno.env.get("PASSWORD_SETUP_URL") || undefined;
  const { error } = await admin.auth.resetPasswordForEmail(email, { redirectTo });
  if (error) console.error("Could not send the password setup email", error);
  return !error;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "Use POST.");

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return fail(500, "The server is not set up correctly (missing keys).");
  }

  // The service-key client: bypasses RLS. Used only after the root check.
  // Implicit flow, so the emailed set-password link carries the session
  // itself and works in any browser (PKCE links need the asking device).
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, flowType: "implicit" },
  });

  // ---- 1. Who is calling? Must be the root admin. --------------------------
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
    return fail(403, "Only the root administrator can create admin accounts.");
  }

  // ---- 2. Validate the form. ----------------------------------------------
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "The form data could not be read.");
  }

  const firstname = text(body.firstname);
  const surname = text(body.surname);
  const username = text(body.username);
  const email = text(body.email).toLowerCase();
  const phone = text(body.phone); // optional, 9 digits after +27
  const station = text(body.station);

  if (!firstname || !surname) return fail(400, "Enter the first name and surname.");
  if (firstname.length > 100 || surname.length > 100) {
    return fail(400, "First name and surname must be at most 100 characters.");
  }
  if (!USERNAME.test(username)) {
    return fail(400, "Username must be 3-30 letters, numbers, _ or .");
  }
  if (!EMAIL.test(email)) return fail(400, "Enter a valid email address.");
  if (phone && !LOCAL_PHONE.test(phone)) {
    return fail(400, "Phone number must be 9 digits, no initial 0.");
  }
  if (!station) return fail(400, "Enter the police station.");
  if (station.length > 150) return fail(400, "Station must be at most 150 characters.");

  // ---- 3. Clear message for a taken username. ------------------------------
  const { data: free, error: usernameError } = await admin.rpc(
    "username_available",
    { p_username: username },
  );
  if (usernameError) return fail(500, "Could not check the username. Try again.");
  if (free !== true) return fail(409, "That username is already taken.");

  // ---- 4. Create the login. ------------------------------------------------
  // Key names in user_metadata must match handle_new_auth_user (migration
  // 20261018100000_admin_accounts.sql).
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    email_confirm: true, // the root admin vouches for the address
    app_metadata: { role: "admin" },
    user_metadata: {
      username,
      firstname,
      surname,
      phonenumber: phone ? `+27${phone}` : "",
      admin_station: station,
      createdby: String(caller.userid),
    },
  });

  if (createError || !created?.user) {
    const code = (createError as { code?: string } | null)?.code;
    if (code === "email_exists" || code === "user_already_exists") {
      return fail(409, "An account with this email already exists.");
    }
    if (createError?.message?.includes("Database error")) {
      return fail(409, "The username is already in use.");
    }
    console.error("createUser failed", createError);
    return fail(500, "The account could not be created. Try again.");
  }

  // ---- 5. Make sure the rows are admin rows. -------------------------------
  // Supabase Auth INSERTs the login first and adds app_metadata (our role) a
  // moment later, so the sign-up trigger may make a citizen first; the
  // on_auth_user_role_set trigger then fixes it. This checks, and fixes it
  // here if needed.
  const authId = created.user.id;
  const undo = async (userid?: number) => {
    if (userid != null) await admin.from("User").delete().eq("userid", userid);
    await admin.auth.admin.deleteUser(authId);
  };

  const { data: row, error: rowError } = await admin
    .from("User")
    .select("userid, role")
    .eq("authid", authId)
    .maybeSingle();
  if (rowError || !row) {
    console.error("User row missing after createUser", rowError);
    await undo();
    return fail(500, "The account could not be created. Try again.");
  }

  const steps = [];
  if (row.role !== "admin") {
    steps.push(
      () => admin.from("citizen").delete().eq("userid", row.userid),
      () => admin.from("User").update({ role: "admin" }).eq("userid", row.userid),
    );
  }
  steps.push(() =>
    admin.from("admin").upsert(
      {
        userid: row.userid,
        admin_type: "normal",
        admin_station: station,
        createdby: caller.userid,
      },
      { onConflict: "userid" },
    )
  );
  for (const step of steps) {
    const { error } = await step();
    if (error) {
      console.error("Could not make the account an admin", error);
      await undo(row.userid);
      return fail(500, "The account could not be created. Try again.");
    }
  }

  // ---- 6. Email a link to choose a password. -------------------------------
  const emailSent = await sendPasswordSetup(admin, email);

  return reply(201, { userid: row.userid, email, email_sent: emailSent });
});
