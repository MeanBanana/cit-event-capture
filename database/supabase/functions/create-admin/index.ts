// create-admin: makes a login for a police station's admin. Called from the
// "New admin" form in web/admin-console, and only the root admin may use it.
//
// Same reason as create-investigator for living here: it needs the service
// key, and that key must never end up in a web page.
//
// The sign-up triggers create the "User" and admin rows. New admins are
// always 'normal' (not root), with their station taken from
// user_metadata.admin_station. Like investigators they get a temporary
// password and have to change it on first sign-in.
//
// Deploy from database/:  supabase functions deploy create-admin
// verify_jwt is off in config.toml because we check the caller ourselves.

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

// Keep these in line with the console and the database checks
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

  // Service-key client, bypasses RLS. Don't use it until we know it's root calling.
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. caller has to be the root admin
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
  const station = text(body.station);
  // don't trim the password, use it exactly as typed
  const password = typeof body.password === "string" ? body.password : "";

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
  const badPassword = passwordProblem(password);
  if (badPassword) return fail(400, badPassword);

  // 3. nicer message for a taken username (the database checks it anyway)
  const { data: free, error: usernameError } = await admin.rpc(
    "username_available",
    { p_username: username },
  );
  if (usernameError) return fail(500, "Could not check the username. Try again.");
  if (free !== true) return fail(409, "That username is already taken.");

  // 4. create the login. user_metadata keys have to match what
  // handle_new_auth_user reads (20261018100000_admin_accounts.sql).
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true, // root is vouching for the address
    app_metadata: { role: "admin", must_change_password: true },
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
    if (code === "weak_password") {
      return fail(400, "That temporary password is too weak. Generate a new one.");
    }
    if (createError?.message?.includes("Database error")) {
      return fail(409, "The username is already in use.");
    }
    console.error("createUser failed", createError);
    return fail(500, "The account could not be created. Try again.");
  }

  // 5. make sure it really is an admin. See create-investigator for the long
  // version: the trigger can briefly create a citizen because Auth adds the
  // role a moment after the insert. Normally on_auth_user_role_set fixes it,
  // this is the backstop.
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

  return reply(201, { userid: row.userid, email });
});
