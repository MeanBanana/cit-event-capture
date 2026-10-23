// delete-submission: the Delete button on a rejected submission in the admin
// app (SupabaseService.deleteSubmission). Body is { incidentid }.
//
// The database function delete_rejected_submission does the row side and
// refuses anything that isn't rejected (so not pending, accepted or a
// duplicate). Then we wipe <incidentid>/ out of the submissions bucket.
//
// It has to be an Edge Function because the bucket doesn't allow deletes
// from the app at all (footage is evidence), so we need the service key.
//
// Deploy from database/:  supabase functions deploy delete-submission
// verify_jwt is off in config.toml, we check the caller is an admin ourselves.

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

  // 2. delete the rows (the db function makes sure it's actually rejected)
  const { error: dbError } = await admin.rpc("delete_rejected_submission", {
    p_incidentid: incidentid,
  });
  if (dbError) {
    // these come from our own checks and are already worded for the admin
    if (dbError.code === "P0002" || dbError.code === "P0001") {
      return fail(409, dbError.message);
    }
    console.error("delete_rejected_submission failed", dbError);
    return fail(500, "The submission could not be deleted. Try again.");
  }

  // 3. delete everything under <incidentid>/ in the bucket
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
        if (item.id === null) await walk(path); // folders have no id
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
    // The rows are already gone at this point. Any files left behind get
    // picked up later by backend/cleanup_storage.py.
    console.error("Could not delete all files", error);
    return reply(200, {
      incidentid,
      files_removed: removed,
      warning: "The submission was deleted, but some of its files could not be removed.",
    });
  }

  return reply(200, { incidentid, files_removed: removed });
});
