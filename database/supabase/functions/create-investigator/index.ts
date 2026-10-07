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
//   5. Returns { userid, email }.
//
// The account has no password. The investigator sets one on their own phone
// with "Forgot password?" on the login page (reset links only open on the
// phone that asked for them, so this function does not send one).
//
// Deploy (from the database/ folder):
//   supabase functions deploy create-investigator
// verify_jwt is off in config.toml because this function checks the caller
// itself (step 1), which also works with Supabase's newer JWT signing keys.

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

// Same rules as the app and the database.
const USERNAME = /^[A-Za-z0-9_.]{3,30}$/; // "User"_username_format check
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LOCAL_PHONE = /^\d{9}$/; // the 9 digits after +27

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "Use POST.");

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return fail(500, "The server is not set up correctly (missing keys).");
  }

  // The service-key client: bypasses RLS. Used only after the admin check.
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
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

  // ---- 5. Return the new "User".userid (made by the trigger). -------------
  const { data: row } = await admin
    .from("User")
    .select("userid")
    .eq("authid", created.user.id)
    .maybeSingle();

  return reply(201, { userid: row?.userid ?? null, email });
});
