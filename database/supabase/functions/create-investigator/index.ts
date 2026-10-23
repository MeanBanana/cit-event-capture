// create-investigator: makes a login for a new investigator. The admin app's
// "+ New investigator" form calls this (SupabaseService.createInvestigator).
//
// It lives here rather than in the app because creating someone else's
// account and handing it the investigator role needs the service key, and
// that key can do literally anything in the project. It stays on Supabase as
// an env var and never ships in the app.
//
// The admin picks a temporary password and passes it on. On first login the
// app forces the investigator to pick their own (must_change_password, which
// the database clears once they change it, see 20261020100000).
//
// Deploy from database/:  supabase functions deploy create-investigator
// verify_jwt is off in config.toml since we check the caller ourselves below,
// which also copes with Supabase's newer JWT signing keys.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** JSON reply. Errors are always { error: "something the admin can read" }. */
function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const fail = (status: number, message: string) =>
  reply(status, { error: message });

/** Trimmed string, or "" if it isn't a string at all. */
const text = (value: unknown) => (typeof value === "string" ? value.trim() : "");

// Keep these in line with the app and the database checks
const USERNAME = /^[A-Za-z0-9_.]{3,30}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LOCAL_PHONE = /^\d{9}$/; // the 9 digits after +27

/** What's wrong with the temporary password, or null if it's fine. */
function passwordProblem(password: string): string | null {
  if (password.length < 8 || password.length > 72 ||
      !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
    return "The temporary password needs 8-72 characters, with letters and numbers.";
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "Use POST.");

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return fail(500, "The server is not set up correctly (missing keys).");
  }

  // Service-key client, bypasses RLS. Don't use it for anything until we've checked the caller.
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. caller has to be a logged-in admin
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

  // 2. validate the form
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
  const phone = text(body.phone); // optional
  const rank = text(body.rank); // optional
  const badgenumber = text(body.badgenumber).toUpperCase();
  const station = text(body.station);
  const unit = text(body.unit); // optional
  // don't trim the password, use it exactly as typed
  const password = typeof body.password === "string" ? body.password : "";

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
  const badPassword = passwordProblem(password);
  if (badPassword) return fail(400, badPassword);

  // 3. check for the usual clashes up front so we can give a decent message.
  // The database enforces these anyway.
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

  // 4. create the login. The user_metadata keys have to match what
  // handle_new_auth_user reads (user_role_tables migration).
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true, // the admin is vouching for the address
    app_metadata: { role: "investigator", must_change_password: true },
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
    if (code === "weak_password") {
      return fail(400, "That temporary password is too weak. Generate a new one.");
    }
    if (createError?.message?.includes("Database error")) {
      // the sign-up trigger rejected it, most likely someone grabbed the name a moment ago
      return fail(409, "The username or badge number is already in use.");
    }
    console.error("createUser failed", createError);
    return fail(500, "The account could not be created. Try again.");
  }

  // 5. make sure it really is an investigator.
  // Auth inserts the auth.users row first and only adds app_metadata (where
  // our role lives) a moment later, so the sign-up trigger sees no role and
  // makes a citizen. The on_auth_user_role_set trigger (20261007120000)
  // normally fixes that right away, this is just a backstop in case that
  // migration isn't on the database.
  const authId = created.user.id;

  // Throw away the half-made account so the admin can just try again
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

  return reply(201, { userid: row.userid, email });
});
