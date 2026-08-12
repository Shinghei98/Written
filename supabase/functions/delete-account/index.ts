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
// **The cascade is not the whole deletion, and for months this file assumed it
// was.** Storage has no foreign keys, so deleting the auth row removed every
// row about a person and left their photographs in the bucket. It was not a
// theory: production held **22 `profile-photos` folders for 5 accounts** and 6
// orphaned `chat-media` folders — roughly 60 objects belonging to people who
// had deleted their accounts. The privacy page promises deletion and 5.1.1(v)
// is the reason this function exists, so the objects go first now.
//
// **The two buckets are keyed differently and that is the whole difficulty:**
//
//   `profile-photos`  <user_id>/<position>.<ext>      — the folder is the user
//   `chat-media`      <conversation_id>/<uuid>.<ext>  — the folder is not
//
// So a person's attachments cannot be found by folder name. Their conversation
// ids have to be read **before** the auth row goes, because `conversations`
// cascades away with it and afterwards there is nothing left to look them up
// by. That ordering is also the safe one: a failed purge leaves an account that
// can retry, while a deleted auth row leaves a session that cannot.
//
// **A failed purge fails the request.** This codebase's recurring defect is a
// call that can fail whose result nobody reads, and a deletion that half
// succeeds while reporting success is the worst instance of it — the account
// disappears, the person believes they are gone, and their face is still in a
// bucket. Better to answer 500 and be retried.
//
// No imports, on purpose. A dependency-free function pastes into the dashboard
// editor and runs on any version of the edge runtime — matching how the app
// itself talks to Supabase over plain HTTP rather than through an SDK.
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

const admin = {
  apikey: SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

/** Every object key under one folder, paged.
 *
 * Storage's list is capped per call and answers names *relative to the prefix*,
 * so the folder has to be put back on. Paging is not decoration: a chat folder
 * holds one object per attachment ever sent in that thread, and a first page of
 * 100 would silently leave the rest behind — which is exactly the failure this
 * whole change exists to stop.
 */
async function objectsUnder(bucket: string, folder: string): Promise<string[]> {
  const keys: string[] = [];
  const limit = 100;
  for (let offset = 0; ; offset += limit) {
    const response = await fetch(`${SUPABASE_URL}/storage/v1/object/list/${bucket}`, {
      method: "POST",
      headers: admin,
      body: JSON.stringify({ prefix: `${folder}/`, limit, offset }),
    });
    if (!response.ok) {
      throw new Error(`list ${bucket}/${folder}: ${await response.text()}`);
    }
    const page = await response.json();
    if (!Array.isArray(page) || page.length === 0) return keys;
    for (const entry of page) {
      // A folder placeholder has no `id`. Recursing is not needed — neither
      // bucket nests — and skipping it keeps a null key out of the delete.
      if (entry?.name && entry?.id) keys.push(`${folder}/${entry.name}`);
    }
    if (page.length < limit) return keys;
  }
}

async function removeObjects(bucket: string, keys: string[]): Promise<void> {
  if (keys.length === 0) return;
  const response = await fetch(`${SUPABASE_URL}/storage/v1/object/${bucket}`, {
    method: "DELETE",
    headers: admin,
    body: JSON.stringify({ prefixes: keys }),
  });
  if (!response.ok) {
    throw new Error(`delete from ${bucket}: ${await response.text()}`);
  }
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

  let photoCount = 0;
  let mediaCount = 0;
  try {
    // Read first, delete second. Both threads' attachments live under the
    // conversation, so this list is the only route to them once the row is gone.
    const conversationsResponse = await fetch(
      `${SUPABASE_URL}/rest/v1/conversations` +
        `?select=id&or=(user_a.eq.${user.id},user_b.eq.${user.id})`,
      { headers: admin },
    );
    if (!conversationsResponse.ok) {
      throw new Error(`conversations: ${await conversationsResponse.text()}`);
    }
    const conversations = await conversationsResponse.json();

    for (const conversation of conversations) {
      const keys = await objectsUnder("chat-media", conversation.id);
      await removeObjects("chat-media", keys);
      mediaCount += keys.length;
    }

    const photoKeys = await objectsUnder("profile-photos", user.id);
    await removeObjects("profile-photos", photoKeys);
    photoCount = photoKeys.length;
  } catch (error) {
    // Deliberately before the account is touched, so this is retryable: the
    // session still works and nothing has been half-removed.
    return json({ error: `purge failed: ${error}` }, 500);
  }

  // Cascades through public.users to distilled_records, source_connections,
  // health_signals, health_sports, bans — and semantic_private, where deleting
  // the wrapped-key row is crypto erasure with nothing to remember to call.
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

  // The counts are returned rather than logged, for the reason `functions/push`
  // learned: a diagnosis that only reaches `console` is unfindable when it is
  // wanted, and "deleted, 0 photos" is the shape of this bug coming back.
  return json({
    deleted: user.id,
    photos_removed: photoCount,
    attachments_removed: mediaCount,
  }, 200);
});
