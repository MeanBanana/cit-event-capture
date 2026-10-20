// manage-investigator — Supabase Edge Function
//
// Called by the admin app's Investigators tab (SupabaseService
// updateInvestigator / deleteInvestigator):
//
//   { action: "update", userid, firstname, surname, username, email, phone,
//     rank, badgenumber, station, unit, password? }
//       Changes the investigator's details and log-in. A new email changes
//       the address they log in with; a new password is a TEMPORARY one
//       (must_change_password: they choose their own at the next log-in).
//
//   { action: "delete", userid }
//       Removes the account (database function remove_investigator_account):
//         'deleted'    nothing they did is on record -> rows + login deleted
//         'anonymised' they worked on cases -> their work stays in the case
//                      records as "Former investigator", and the login is
//                      blocked for good and moved to a placeholder email
//
// Why here and not in the app: changing someone else's login (email,
// password) or deleting it needs the service key, which must never be in
// the app. The key stays on Supabase's servers.
//
// Deploy (from the database/ folder):
//   supabase functions deploy manage-investigator
// verify_jwt is off in config.toml because this function checks the caller
// itself (logged in AND an admin), like create-investigator.

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

// Same rules as the app, create-investigator and the database.
const USERNAME = /^[A-Za-z0-9_.]{3,30}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LOCAL_PHONE = /^\d{9}$/; // the 9 digits after +27

function passwordProblem(password: string): string | null {
  if (password.length < 8 || password.length > 72 ||
      !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
    return "The temporary password needs 8-72 characters, with letters and numbers.";
  }
  return null;
}

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

  // ---- Who is calling? Must be a logged-in admin. ---------------------------
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
    return fail(403, "Only a system administrator can change investigator accounts.");
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "The form data could not be read.");
  }
  const action = text(body.action);
  const userid = typeof body.userid === "number" ? body.userid : Number(body.userid);
  if (!Number.isInteger(userid) || userid <= 0) return fail(400, "Which investigator?");

  // ---- The investigator being changed. -------------------------------------
  const { data: target, error: targetError } = await admin
    .from("User")
    .select("userid, authid, role, username, email")
    .eq("userid", userid)
    .maybeSingle();
  if (targetError) return fail(500, "Could not load the account. Try again.");
  const { data: invRow } = await admin
    .from("investigator")
    .select("userid")
    .eq("userid", userid)
    .maybeSingle();
  if (!target || target.role !== "investigator" || !invRow) {
    return fail(404, "That investigator account no longer exists. Refresh the list.");
  }

  // =========================================================================
  if (action === "delete") {
    const { data: removed, error: removeError } = await admin.rpc(
      "remove_investigator_account",
      { p_userid: userid },
    );
    if (removeError || !removed) {
      console.error("remove_investigator_account failed", removeError);
      return fail(500, "The account could not be deleted. Try again.");
    }
    const mode = (removed as { mode: string }).mode;
    if (mode === "deleted") {
      const { error } = await admin.auth.admin.deleteUser(target.authid);
      if (error) console.error("deleteUser failed (the account rows are gone)", error);
    } else {
      // Their work stays on record, so the login can't be deleted; block it
      // for good and free the real email address.
      const { error } = await admin.auth.admin.updateUserById(target.authid, {
        email: (removed as { email: string }).email,
        email_confirm: true,
        password: randomPassword(),
        ban_duration: "876000h", // ~100 years
        user_metadata: {},
      });
      if (error) {
        console.error("Could not block the login", error);
        return fail(500, "The account was removed, but its log-in could not be blocked. " +
          "Ask your Supabase admin to delete it under Authentication → Users.");
      }
    }
    return reply(200, { mode });
  }

  if (action !== "update") return fail(400, "Unknown action.");

  // =========================================================================
  // ---- Validate the form (same rules as create-investigator). -------------
  const firstname = text(body.firstname);
  const surname = text(body.surname);
  const username = text(body.username);
  const email = text(body.email).toLowerCase();
  const phone = text(body.phone);
  const rank = text(body.rank);
  const badgenumber = text(body.badgenumber).toUpperCase();
  const station = text(body.station);
  const unit = text(body.unit);
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
  if (password) {
    const bad = passwordProblem(password);
    if (bad) return fail(400, bad);
  }

  // ---- Clashes with other accounts. -----------------------------------------
  if (username.toLowerCase() !== String(target.username).toLowerCase()) {
    const { data: free, error } = await admin.rpc("username_available", { p_username: username });
    if (error) return fail(500, "Could not check the username. Try again.");
    if (free !== true) return fail(409, "That username is already taken.");
  }
  const { data: badgeTaken, error: badgeError } = await admin
    .from("investigator")
    .select("userid")
    .eq("badgenumber", badgenumber)
    .neq("userid", userid)
    .maybeSingle();
  if (badgeError) return fail(500, "Could not check the badge number. Try again.");
  if (badgeTaken) return fail(409, "That badge number is already in use.");

  // ---- 1. The log-in email (the database copies it to "User".email). -------
  if (email !== String(target.email).toLowerCase()) {
    const { error } = await admin.auth.admin.updateUserById(target.authid, {
      email,
      email_confirm: true, // the admin vouches for the address
    });
    if (error) {
      const code = (error as { code?: string }).code;
      if (code === "email_exists" || /already/i.test(error.message ?? "")) {
        return fail(409, "Another account already uses that email.");
      }
      console.error("email update failed", error);
      return fail(500, "The email could not be changed. Try again.");
    }
  }

  // ---- 2. Name, username, phone, police details. --------------------------
  const { error: userError } = await admin
    .from("User")
    .update({
      firstname,
      surname,
      username,
      phonenumber: phone ? `+27${phone}` : null,
    })
    .eq("userid", userid);
  if (userError) {
    if (userError.code === "23505") return fail(409, "That username is already taken.");
    console.error("User update failed", userError);
    return fail(500, "The details could not be saved. Try again.");
  }
  const { error: invError } = await admin
    .from("investigator")
    .update({ rank: rank || null, badgenumber, station, unit: unit || null })
    .eq("userid", userid);
  if (invError) {
    if (invError.code === "23505") return fail(409, "That badge number is already in use.");
    console.error("investigator update failed", invError);
    return fail(500, "The police details could not be saved. Try again.");
  }

  // ---- 3. A new temporary password (optional). ------------------------------
  // Two steps: the database clears must_change_password whenever the
  // password changes, so the flag is set AFTER the new password.
  if (password) {
    const { error: pwError } = await admin.auth.admin.updateUserById(target.authid, { password });
    if (pwError) {
      const code = (pwError as { code?: string }).code;
      if (code === "weak_password") {
        return fail(400, "That temporary password is too weak. Generate a new one.");
      }
      console.error("password update failed", pwError);
      return fail(500, "The details were saved, but the password could not be changed. Try again.");
    }
    const { data: current } = await admin.auth.admin.getUserById(target.authid);
    const appMeta = { ...(current?.user?.app_metadata ?? {}), must_change_password: true };
    const { error: flagError } = await admin.auth.admin.updateUserById(target.authid, {
      app_metadata: appMeta,
    });
    if (flagError) console.error("could not set must_change_password", flagError);
  }

  return reply(200, { userid, password_changed: Boolean(password) });
});
