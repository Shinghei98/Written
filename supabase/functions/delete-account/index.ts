// Deletes the caller's account outright — App Review guideline 5.1.1(v).
//
// Why this can't live in the app: every table in `public` cascades from
// `auth.users`, so one delete there removes the lot. But removing an
// `auth.users` row is a `service_role` operation, and `service_role` bypasses
// row-level security entirely — RLS *is* the whole authorisation layer here, so
// that key shipping inside the binary would hand every copy of the app the keys
// to every account. It stays on the server; this function is the only thing
// holding it.
//
// No imports, on purpose. Two REST calls do the whole job, and a dependency-free
// function pastes into the dashboard editor and runs on any version of the edge
// runtime — matching how the app itself talks to Supabase over plain HTTP rather
// than through an SDK.
//
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected by
// the platform. Never add them to a .env, and never commit the service role key.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Missing Authorization header" }, 401);

  // Who is calling is established from their own JWT and never from the request
  // body. Taking a user id from the body would let anyone delete anyone.
  const whoResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: authorization },
  });
  if (!whoResponse.ok) return json({ error: "Not signed in" }, 401);

  const user = await whoResponse.json();
  if (!user?.id) return json({ error: "No user on that token" }, 401);

  // Cascades through public.users to distilled_records, source_connections,
  // health_signals, health_sports and bans.
  const deleteResponse = await fetch(
    `${SUPABASE_URL}/auth/v1/admin/users/${user.id}`,
    {
      method: "DELETE",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
    },
  );

  if (!deleteResponse.ok) {
    return json({ error: await deleteResponse.text() }, 500);
  }

  return json({ deleted: user.id }, 200);
});
