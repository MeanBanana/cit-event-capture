// create-investigator — Supabase Edge Function
//
// Called by the admin app's "+ New investigator" form
// (SupabaseService.createInvestigator). Creates an investigator's login.
//
// Why this runs here and not in the app:
//   Creating someone else's account and giving it the 'investigator' role
//   needs the service key, which can do anything in the project. That key
//   must never be inside the app, so the app calls this function instead and
//   the key stays on Supabase's servers (as an environment variable).
//
// What it does:
//   1. Checks the caller is logged in AND is an admin ("User".role).
//   2. Validates the form values (same rules as the app).
//   3. Checks the username and badge number aren't taken (clear messages).
//   4. auth.admin.createUser with role 'investigator' in app_metadata (only
//      the service key can set that). The on_auth_user_created trigger then
//      creates the "User" and investigator rows from user_metadata.
//   5. Makes sure the rows are investigator rows (see step 5 below).
//   6. Emails the investigator a link to choose their password, then
//      returns { userid, email, email_sent }.
//
// The account has no password until then. The link opens the web admin
// console's set-password page (PASSWORD_SETUP_URL secret), which works on
// any device; the app's own "Forgot password?" links only open on the phone
// that asked for them, so a link sent from here could not use those.
//
// Deploy (from the database/ folder):
//   supabase functions deploy create-investigator
// verify_jwt is off in config.toml because this function checks the caller
// itself (step 1), which also works with Supabase's newer JWT signing keys.

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

// Same rules as the app and the database.
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

  // The service-key client: bypasses RLS. Used only after the admin check.
  // Implicit flow, so the emailed set-password link carries the session
  // itself and works in any browser (PKCE links need the asking device).
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, flowType: "implicit" },
  });

  // ---- 1. Who is calling? Must be a logged-in admin. ----------------------
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return fail(401, "Please log in again.");

  const { data: auth, error: authError } = await admin.auth.getUser(token);
  if (authError || !auth?.user) return fail(401, "Please log in again.");

  const { data: caller, error: callerError } = await admin
    .from("User")
    .select("role")
    .eq("authid", auth.user.id)
    .maybeSingle();
  if (callerError) return fail(500, "Could not check your account. Try again.");
  if (caller?.role !== "admin") {
    return fail(403, "Only a system administrator can add investigators.");
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
  const rank = text(body.rank); // optional
  const badgenumber = text(body.badgenumber).toUpperCase();
  const station = text(body.station);
  const unit = text(body.unit); // optional

  if (!firstname || !surname) return fail(400, "Enter the first name and surname.");
  if (!USERNAME.test(username)) {
    return fail(400, "Username must be 3-30 letters, numbers, _ or .");
  }
  if (!EMAIL.test(email)) return fail(400, "Enter a valid email address.");
  if (phone && !LOCAL_PHONE.test(phone)) {
    return fail(400, "Phone number must be 9 digits, no initial 0.");
  }
  if (!badgenumber) return fail(400, "Enter the badge number.");
  if (!station) return fail(400, "Enter the station.");
  if (firstname.length > 100 || surname.length > 100) {
    return fail(400, "First name and surname must be at most 100 characters.");
  }
  if (rank.length > 50 || badgenumber.length > 50) {
    return fail(400, "Rank and badge number must be at most 50 characters.");
  }
  if (station.length > 150 || unit.length > 100) {
    return fail(400, "Station must be at most 150 characters and unit at most 100.");
  }

  // ---- 3. Clear messages for the usual clashes. ---------------------------
  // (The database still enforces both; these just explain it nicely.)
  const { data: free, error: usernameError } = await admin.rpc(
    "username_available",
    { p_username: username },
  );
  if (usernameError) return fail(500, "Could not check the username. Try again.");
  if (free !== true) return fail(409, "That username is already taken.");

  const { data: badgeTaken, error: badgeError } = await admin
    .from("investigator")
    .select("userid")
    .eq("badgenumber", badgenumber)
    .maybeSingle();
  if (badgeError) return fail(500, "Could not check the badge number. Try again.");
  if (badgeTaken) return fail(409, "That badge number is already in use.");

  // ---- 4. Create the login. ------------------------------------------------
  // The key names in user_metadata must match what handle_new_auth_user
  // reads (see the user_role_tables migration).
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    email_confirm: true, // the admin vouches for the address
    app_metadata: { role: "investigator" },
    user_metadata: {
      username,
      firstname,
      surname,
      phonenumber: phone ? `+27${phone}` : "",
      rank,
      badgenumber,
      station,
      unit,
    },
  });

  if (createError || !created?.user) {
    const code = (createError as { code?: string } | null)?.code;
    if (code === "email_exists" || code === "user_already_exists") {
      return fail(409, "An account with this email already exists.");
    }
    if (createError?.message?.includes("Database error")) {
      // The sign-up trigger refused the data (e.g. taken at the same moment).
      return fail(409, "The username or badge number is already in use.");
    }
    console.error("createUser failed", createError);
    return fail(500, "The account could not be created. Try again.");
  }

  // ---- 5. Make sure the rows are investigator rows. ------------------------
  // Supabase Auth saves a new login in two steps: it INSERTs the auth.users
  // row first and adds app_metadata (our role) a moment later. The sign-up
  // trigger runs on the INSERT, sees no role yet and makes a CITIZEN. The
  // on_auth_user_role_set trigger (migration 20261007120000) normally fixes
  // that straight away; this step makes sure of it, so the account is right
  // even if that migration has not been run on the database.
  const authId = created.user.id;

  // Removes the half-made account so the admin can simply try again.
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

  if (row.role !== "investigator") {
    const steps = [
      () => admin.from("citizen").delete().eq("userid", row.userid),
      () => admin.from("User").update({ role: "investigator" }).eq("userid", row.userid),
      () =>
        admin.from("investigator").insert({
          userid: row.userid,
          rank: rank || null,
          badgenumber,
          station,
          unit: unit || null,
        }),
    ];
    for (const step of steps) {
      const { error } = await step();
      if (error) {
        console.error("Could not make the account an investigator", error);
        await undo(row.userid);
        if (error.code === "23505") {
          return fail(409, "The username or badge number is already in use.");
        }
        return fail(500, "The account could not be created. Try again.");
      }
    }
  }

  // ---- 6. Email a link to choose a password. -------------------------------
  const emailSent = await sendPasswordSetup(admin, email);

  return reply(201, { userid: row.userid, email, email_sent: emailSent });
});
