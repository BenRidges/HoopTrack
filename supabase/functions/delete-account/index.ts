// delete-account: deletes the signed-in user and everything stored for them.
//
// Called by the app (Profile → Delete account) with the user's own JWT.
// App Store Guideline 5.1.1(v) requires in-app account deletion for any app
// that lets people create an account.
//
// Order: synced rows, then shared-telemetry files, then the auth user, so a
// failure part-way leaves the account in place and the app can retry.
//
// Deploy:  supabase functions deploy delete-account
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided to functions
// automatically; the service key never leaves the server.)

import { createClient } from "jsr:@supabase/supabase-js@2";

// Children before parents, in case the foreign keys don't cascade.
const TABLES = ["shot_records", "training_sessions", "goal_records", "earned_badges", "player_profiles"];
const TELEMETRY_BUCKET = "telemetry-sessions";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "use POST" }, 405);

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "not signed in" }, 401);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Who is asking: resolved from their token, never from the request body.
  const { data: { user }, error: userError } = await admin.auth.getUser(jwt);
  if (userError || !user) return json({ error: "invalid or expired session" }, 401);

  for (const table of TABLES) {
    const { error } = await admin.from(table).delete().eq("user_id", user.id);
    if (error) return json({ error: `couldn't delete ${table}: ${error.message}` }, 500);
  }

  // Shared sessions live under <user id>/<session id>/; the app writes the
  // id upper-case, so check both spellings.
  const bucket = admin.storage.from(TELEMETRY_BUCKET);
  for (const root of new Set([user.id, user.id.toUpperCase()])) {
    const { data: sessions, error } = await bucket.list(root, { limit: 1000 });
    if (error) return json({ error: `couldn't list telemetry: ${error.message}` }, 500);
    for (const session of sessions ?? []) {
      const folder = `${root}/${session.name}`;
      const { data: files } = await bucket.list(folder, { limit: 1000 });
      const paths = (files ?? []).map((f) => `${folder}/${f.name}`);
      // Batches keep each request small.
      for (let i = 0; i < paths.length; i += 100) {
        const { error: removeError } = await bucket.remove(paths.slice(i, i + 100));
        if (removeError) return json({ error: `couldn't delete telemetry: ${removeError.message}` }, 500);
      }
    }
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) return json({ error: `couldn't delete the account: ${deleteError.message}` }, 500);

  return json({ deleted: true });
});
