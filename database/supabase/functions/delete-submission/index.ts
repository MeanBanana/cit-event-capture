// delete-submission — Supabase Edge Function
//
// Called by the admin app's Delete button on a REJECTED submission
// (SupabaseService.deleteSubmission). Body: { incidentid }.
//
//   1. Checks the caller is a logged-in admin.
//   2. Database function delete_rejected_submission: only rejected
//      submissions (not pending, accepted or duplicates); removes it, its
//      files' rows and everything the AI found in them.
//   3. Deletes its files (footage + AI pictures) under <incidentid>/ in the
//      private 'submissions' bucket.
//
// Why here and not in the app: the bucket doesn't let anyone delete files
// from the app (footage is evidence), so this uses the service key, which
// stays on Supabase's servers.
//
// Deploy (from the database/ folder):
//   supabase functions deploy delete-submission
// verify_jwt is off in config.toml because this function checks the caller
// itself (logged in AND an admin), like create-investigator.

import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "submissions";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const fail = (status: number, message: string) =>
  reply(status, { error: message });

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

  // ---- 1. Must be a logged-in admin. -----------------------------------------
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
    return fail(403, "Only a system administrator can delete submissions.");
  }

  let incidentid: number;
  try {
    const body = await req.json();
    incidentid = Number(body?.incidentid);
  } catch {
    return fail(400, "The request could not be read.");
  }
  if (!Number.isInteger(incidentid) || incidentid <= 0) return fail(400, "Which submission?");

  // ---- 2. The database rows (the function checks it is rejected). ----------
  const { error: dbError } = await admin.rpc("delete_rejected_submission", {
    p_incidentid: incidentid,
  });
  if (dbError) {
    // our own checks have messages meant for the admin
    if (dbError.code === "P0002" || dbError.code === "P0001") {
      return fail(409, dbError.message);
    }
    console.error("delete_rejected_submission failed", dbError);
    return fail(500, "The submission could not be deleted. Try again.");
  }

  // ---- 3. Its files: everything under <incidentid>/ ------------------------
  const paths: string[] = [];
  const walk = async (folder: string) => {
    for (let offset = 0; ; offset += 1000) {
      const { data, error } = await admin.storage.from(BUCKET).list(folder, {
        limit: 1000,
        offset,
      });
      if (error) throw error;
      for (const item of data ?? []) {
        const path = `${folder}/${item.name}`;
        if (item.id === null) await walk(path); // a folder
        else paths.push(path);
      }
      if (!data || data.length < 1000) return;
    }
  };

  let removed = 0;
  try {
    await walk(String(incidentid));
    for (let i = 0; i < paths.length; i += 100) {
      const { error } = await admin.storage.from(BUCKET).remove(paths.slice(i, i + 100));
      if (error) throw error;
      removed += Math.min(100, paths.length - i);
    }
  } catch (error) {
    // The submission is already gone; leftover files are cleaned up by
    // backend/cleanup_storage.py (folders of submissions that no longer exist).
    console.error("Could not delete all files", error);
    return reply(200, {
      incidentid,
      files_removed: removed,
      warning: "The submission was deleted, but some of its files could not be removed.",
    });
  }

  return reply(200, { incidentid, files_removed: removed });
});
