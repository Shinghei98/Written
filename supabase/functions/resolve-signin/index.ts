// Answers one question: does this session belong to a real account?
//
// **Written because Supabase cannot be asked to sign somebody in without also
// signing them up.** The `id_token` grant creates a user when no identity
// matches, so "there is no account for this Apple ID" is only knowable *after*
// one has been made. The app calls this immediately after an Apple or Google
// exchange and refuses the sign-in if the answer is no.
//
// The orphan then has to go, and that is not tidiness. An abandoned auth user
// **holds the provider identity**, so the same person could never later link
// that Google account to their real one — the identity would already belong to
// a ghost. Leaving them would quietly make the feature impossible for exactly
// the people who hit this path.
//
// The judgement is here rather than in the app because only `service_role` can
// see enough to make it safely: `auth.users.created_at`, and whether the
// account has anything in it. The app can see neither.
//
// No imports, matching `delete-account` and `push`: plain `fetch`, so this
// pastes into the dashboard editor and runs on any version of the edge runtime.
//
// Deploy with JWT verification ON — unlike `push`, this one is called by the
// app with a real session and has nothing else to authenticate with.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/// How recently an account must have been created to count as one this
/// sign-in just made. Two minutes is far longer than an OAuth round trip and
/// far shorter than anything a real user could accumulate.
const ORPHAN_WINDOW_MS = 2 * 60 * 1000;

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

async function admin(path: string): Promise<unknown> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
  });
  if (!response.ok) return null;
  return await response.json();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Missing Authorization header" }, 401);

  // Who is calling comes from their own JWT and never from the body — the same
  // rule `delete-account` states, and for the same reason: a user id taken from
  // a request body would let anyone delete anyone.
  const whoResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: authorization },
  });
  if (!whoResponse.ok) return json({ error: "Not signed in" }, 401);

  const user = await whoResponse.json();
  if (!user?.id) return json({ error: "No user on that token" }, 401);

  // **A phone is what makes an account real**, because a phone number is the
  // only way to create one. Anything holding a phone was made deliberately by
  // somebody who received an SMS.
  const rows = await admin(`users?id=eq.${user.id}&select=phone`);
  const phone = Array.isArray(rows) && rows.length > 0 ? rows[0]?.phone : null;

  if (phone) return json({ existing: true }, 200);

  // No phone. Either Supabase made this account moments ago for an identity
  // nobody has linked, or it is an older account from before the rule. The two
  // get very different treatment.
  const createdAt = Date.parse(user.created_at ?? "");
  const isFresh = Number.isFinite(createdAt) &&
    Date.now() - createdAt < ORPHAN_WINDOW_MS;

  // **Emptiness is checked, not assumed.** `created_at` alone would be enough
  // in every case anybody has thought of, and the cost of being wrong is
  // somebody's account, so it is worth a second question. `limit=1` because the
  // count does not matter — only whether there is anything at all.
  const records = await admin(`distilled_records?user_id=eq.${user.id}&select=user_id&limit=1`);
  const photos = await admin(`photos?user_id=eq.${user.id}&select=user_id&limit=1`);
  const isEmpty = Array.isArray(records) && records.length === 0 &&
    Array.isArray(photos) && photos.length === 0;

  if (!isFresh || !isEmpty) {
    // An older or non-empty account. Refuse the sign-in — it still has no phone
    // and so is not reachable under the new rule — but **never delete it**.
    // Somebody's data is on the end of this, and a migration path for these
    // accounts is a product decision rather than something to do by inference
    // inside a sign-in check.
    return json({ existing: false, deleted: false }, 200);
  }

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

  // The body carries the outcome rather than only a status, following the
  // lesson `push` records: what a function needs to say should travel in the
  // response, where it can be read without a log viewer.
  return json({
    existing: false,
    deleted: deleteResponse.ok,
    detail: deleteResponse.ok ? null : await deleteResponse.text(),
  }, 200);
});
