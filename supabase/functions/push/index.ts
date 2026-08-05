// Sends one notification to one person's devices.
//
// Called by database triggers rather than by the app — a like, a match and a
// message all happen *to* somebody who is by definition not the one making the
// request, so nothing on the sender's phone can be trusted to tell the
// recipient's phone about it.
//
// No imports, matching `delete-account`: plain `fetch` plus Web Crypto, which
// means this pastes into the dashboard editor and runs on any version of the
// edge runtime.
//
// **APNs authentication is a JWT you sign yourself**, not a static key. The
// `.p8` from Apple is an ES256 private key; the header carries its Key ID, the
// payload carries the Team ID and an issue time, and Apple rejects a token older
// than an hour and refuses one minted more than once every twenty minutes. So it
// is cached for the life of the isolate.
//
// Secrets, all set with `supabase secrets set` and none of them ever committed:
//
//   APNS_KEY_P8     the file's contents, newlines and all
//   APNS_KEY_ID     the ten characters in the filename
//   APNS_TEAM_ID    947DHTL37S
//   APNS_TOPIC      com.written.datingapp
//   PUSH_SECRET     shared with the triggers; see below
//
// **The `.p8` can send a notification to every install of this app.** It is a
// credential of the same weight as the Supabase secret key and gets the same
// treatment: it downloads once, it lives in the platform's secret store, and it
// never appears in a file, a transcript or a commit.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
// **The name lies and it is still the right one to read.** This project disabled
// its legacy API keys during the July rotation, and CLAUDE.md retired
// `SUPABASE_SERVICE_ROLE_KEY` as a *variable name we choose* for exactly that
// reason — it described a credential that no longer exists. But this variable is
// not ours to name: the platform injects it, and on a project migrated to the
// new key system it now carries the `sb_secret_…` value rather than the old
// `service_role` JWT. So it works, and it is the only one that does.
//
// Reading `SUPABASE_SECRET_KEY` instead is **impossible**, which is worth
// stating because it looks like it should work: Supabase reserves the whole
// `SUPABASE_` prefix and refuses to create a secret using it. A first draft of
// this file preferred that name with this one as a fallback, which would have
// been dead code silently falling through forever.
const SECRET_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const APNS_KEY_P8 = Deno.env.get("APNS_KEY_P8") ?? "";
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_TOPIC = Deno.env.get("APNS_TOPIC") ?? "com.written.datingapp";

// **The triggers call in over HTTP and carry no user session**, so the only
// thing separating them from the open internet is this. Without it anyone who
// learns the function's URL can send any of this app's users a notification
// saying anything.
const PUSH_SECRET = Deno.env.get("PUSH_SECRET") ?? "";

const HOSTS: Record<string, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------- the APNs JWT

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function textToBase64url(text: string): string {
  return base64url(new TextEncoder().encode(text));
}

/// Turns the `.p8` into a signing key.
///
/// Apple's file is already PKCS#8 — that is what the `BEGIN PRIVATE KEY` header
/// means, as against `BEGIN EC PRIVATE KEY`, which is SEC1 and would need
/// converting. So it imports directly and no ASN.1 wrangling is needed.
async function importSigningKey(): Promise<CryptoKey> {
  const body = APNS_KEY_P8
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    // Secrets set through a dashboard field arrive with the newlines mangled in
    // several ways; stripping every kind of whitespace is the one form that
    // survives all of them.
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

let cachedToken: { value: string; issued: number } | null = null;

/// The bearer token APNs wants, minted at most once every thirty minutes.
///
/// Apple rejects a token older than **one hour** and also throttles minting —
/// too many new tokens answers `TooManyProviderTokenUpdates` and starts
/// refusing *sends*, which is the worse failure because it looks like the
/// notification itself being wrong.
async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issued < 1800) return cachedToken.value;

  const header = textToBase64url(
    JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }),
  );
  const payload = textToBase64url(
    JSON.stringify({ iss: APNS_TEAM_ID, iat: now }),
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await importSigningKey(),
    new TextEncoder().encode(`${header}.${payload}`),
  );

  const value = `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
  cachedToken = { value, issued: now };
  return value;
}

// -------------------------------------------------------------------- sending

interface Device {
  token: string;
  environment: string;
}

/// Returns `null` for "could not ask", never `[]`.
///
/// **This distinction is the single most repeated defect in this project** —
/// `PhotoService.paths()` returned `[]` on a dropped request or an expired
/// token, and the one caller treated an empty list as a *decision*, silently
/// un-listing people who had photographs. `SyncService.lastError`,
/// `PhotoService.lastError`, `DiscoveryCardService.lastError` and `record`'s
/// discarded return are the same shape.
///
/// It matters exactly as much here. A dead key answers 401, an empty list looks
/// like somebody who never granted notifications, and the caller reports
/// `{"sent":0,"note":"no devices"}` — a *success*. Every notification would
/// vanish and the logs would say everything was fine.
async function devices(userId: string): Promise<Device[] | null> {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/device_tokens?user_id=eq.${userId}&select=token,environment`,
    {
      headers: {
        apikey: SECRET_KEY,
        Authorization: `Bearer ${SECRET_KEY}`,
      },
    },
  );
  if (!response.ok) {
    console.error(`device_tokens ${response.status}: ${await response.text()}`);
    return null;
  }
  return await response.json();
}

/// Deletes a token APNs has told us is dead.
///
/// **Not tidiness.** A `410 Gone` means that install is gone — deleted, or
/// restored onto another phone — and every future send to it is a wasted round
/// trip. Skipping this is how a token table becomes mostly rubbish within a
/// year, and how one person's uninstalled iPad makes every notification look
/// half-failed.
async function reap(userId: string, token: string): Promise<void> {
  await fetch(
    `${SUPABASE_URL}/rest/v1/device_tokens?user_id=eq.${userId}&token=eq.${token}`,
    {
      method: "DELETE",
      headers: {
        apikey: SECRET_KEY,
        Authorization: `Bearer ${SECRET_KEY}`,
        Prefer: "return=minimal",
      },
    },
  );
}

interface Payload {
  user_id: string;
  title: string;
  body: string;
  // What the app should open. Carried through `aps` as custom keys, which is
  // where a tap handler reads them; nothing draws them yet.
  category?: string;
  thread?: string;
}

async function send(device: Device, payload: Payload): Promise<string> {
  const host = HOSTS[device.environment] ?? HOSTS.production;
  const response = await fetch(`${host}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken()}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      // 10 is "deliver now". A 5 would let iOS hold it back for battery, which
      // for a message is the wrong trade.
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: { title: payload.title, body: payload.body },
        sound: "default",
        // Names the notification's kind so the app can group by conversation
        // and, later, so a service extension can attach a photograph.
        "thread-id": payload.thread ?? payload.category ?? "written",
        // Required for a service extension to be given the chance to run at
        // all. Harmless before one exists.
        "mutable-content": 1,
      },
      category: payload.category ?? "",
    }),
  });

  if (response.status === 200) return "ok";
  if (response.status === 410) {
    await reap(payload.user_id, device.token);
    return "gone";
  }
  // Worth returning rather than swallowing. `BadDeviceToken` here means the row
  // named the wrong host — a sandbox token sent to production or the reverse —
  // and it is otherwise indistinguishable from a notification that simply never
  // arrived.
  return `${response.status} ${await response.text()}`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  // **Two failures, two answers.** These were one condition, and an unset
  // `PUSH_SECRET` was therefore indistinguishable from a caller sending the
  // wrong one — both 401 "Not allowed". That is this project's most expensive
  // recurring shape: a refusal that looks exactly like an absence. It cost an
  // afternoon during setup, where "the secret does not match" and "there is no
  // secret to match" want completely different fixes.
  //
  // Saying which is not a disclosure. A caller who cannot authenticate learns
  // only that the function is misconfigured, and can still do nothing.
  if (!PUSH_SECRET) {
    return json({ error: "PUSH_SECRET is not set on this function" }, 500);
  }
  // Constant-time is overkill for a shared secret compared over HTTPS, but the
  // check itself is not optional: see `PUSH_SECRET` above.
  if (req.headers.get("x-push-secret") !== PUSH_SECRET) {
    return json({ error: "Not allowed" }, 401);
  }
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID) {
    return json({ error: "APNs is not configured" }, 500);
  }

  let payload: Payload;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Bad JSON" }, 400);
  }
  if (!payload?.user_id || !payload?.title) {
    return json({ error: "user_id and title are required" }, 400);
  }

  const targets = await devices(payload.user_id);
  // Could not ask. Reported as a failure and never as "nobody to tell" — see
  // `devices`. Nothing retries it; the point is that the log says which happened.
  if (targets === null) {
    return json({ error: "Could not read device_tokens" }, 500);
  }
  // **Not an error.** Somebody who has never opened the app on a phone, or who
  // declined, has no row here — and a trigger treating that as a failure would
  // make every like by a web-less user look broken.
  if (targets.length === 0) return json({ sent: 0, note: "no devices" }, 200);

  const results = await Promise.all(targets.map((d) => send(d, payload)));
  return json({
    sent: results.filter((r) => r === "ok").length,
    results,
  }, 200);
});
