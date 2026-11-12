// ─────────────────────────────────────────────────────────────────────────────
// Handshake backend — one Supabase Edge Function, four jobs.
//
// Why this exists: the iOS app must never hold an API key (HANDOFF §9). Every
// key lives here as a Supabase secret and the phone talks only to this URL.
//
// Routes (all POST, JSON in / JSON out):
//   /ai/messages          → Anthropic Messages API proxy (moves the key off the phone)
//   /auth/apple           → Sign in with Apple identity token → Handshake session
//   /auth/refresh         → new session from a refresh token
//   /credits/balance      → sends left (signed in)
//   /docuseal/start       → take a send credit, then create a DocuSeal submission, one submitter per box
//   /docuseal/complete    → after Face ID on the phone: mark that submitter signed
//   /docuseal/status      → who has signed (in the app or in a browser)
//   /signwell/start       → create a SignWell document, return an embedded signing URL (Path B)
//   /signwell/status      → poll completion (or wire the webhook later)
//
// Deploy (once you have a Supabase project):
//   supabase secrets set ANTHROPIC_API_KEY=... DOCUSEAL_API_KEY=...   (SIGNWELL_API_KEY only for Path B)
//   supabase functions deploy handshake --no-verify-jwt
//
// Everything defaults to the providers' TEST modes. Flip the two constants at
// the bottom of `providers` when you're ready for real signatures.
// ─────────────────────────────────────────────────────────────────────────────

import { createClient, type User } from "npm:@supabase/supabase-js@2";

const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`Missing secret ${k}`);
  return v;
};

const providers = {
  anthropic: { url: "https://api.anthropic.com/v1/messages" },
  // DOCUSEAL_URL only for local tests against a stand-in server.
  docuseal:  { url: Deno.env.get("DOCUSEAL_URL") ?? "https://api.docuseal.com" }, // test key ends in "+test"
  signwell:  { url: "https://www.signwell.com/api/v1", testMode: true },
};

type Json = Record<string, unknown>;

const json = (body: Json, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const bad = (msg: string, status = 400) => json({ error: msg }, status);

// ── Accounts and send credits ───────────────────────────────────────────────
//
// Pricing (owner, Nov 11, 2026): 2 free sends per Apple ID, then $2.99 a send.
// Only the sender pays; signing is free. The balance lives in Postgres
// (migrations/…_send_credits.sql) and only this function changes it.
//
// Accounts are Supabase Auth users made from Sign in with Apple: the phone
// sends Apple's identity token to /auth/apple and gets a session back; after
// that it sends `Authorization: Bearer <access token>` on every call.
//
// ENFORCE_CREDITS=true (a Supabase secret) makes /docuseal/start refuse
// callers who aren't signed in. Until then a signed-in caller is charged and
// anyone else goes through as before, so builds without Sign in with Apple
// (a Personal Team can't use it) keep working.

const FREE_SENDS = 2;
/** Sending the same contract again (after Revise Contract) is free until this many sends. */
const SENDS_PER_CREDIT = 5;

const enforceCredits = () => Deno.env.get("ENFORCE_CREDITS") === "true";

// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are set by
// Supabase in every edge function.
const admin = () =>
  createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const publicClient = () =>
  createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { auth: { persistSession: false } });

/** A response the router returns as is (a 401 or 402 from deep inside a route). */
class Refusal extends Error {
  constructor(readonly response: Response) { super("refused"); }
}

/** The signed-in caller, or null when the call carries no session. */
async function caller(req: Request): Promise<User | null> {
  const header = req.headers.get("authorization") ?? "";
  const token = header.match(/^Bearer (.+)$/i)?.[1];
  if (!token) return null;
  const { data, error } = await admin().auth.getUser(token);
  if (error || !data.user) throw new Refusal(bad("invalid_session", 401));
  return data.user;
}

async function sha256Hex(text: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Makes the account on first use (with the free sends, once per Apple ID). Returns the balance. */
async function ensureAccount(user: User): Promise<number> {
  // Apple's user id survives deleting the Handshake account; the auth user id doesn't.
  const apple = user.identities?.find((i) => i.provider === "apple");
  const identity = apple ? `apple:${apple.id}` : `user:${user.id}`;
  const { data, error } = await admin().rpc("ensure_account", {
    p_user: user.id,
    p_identity_hash: await sha256Hex(identity),
    p_free_sends: FREE_SENDS,
  });
  if (error) throw new Error(error.message);
  return data as number;
}

const sessionJson = (s: { access_token: string; refresh_token: string; expires_at?: number } | null) =>
  s ? { accessToken: s.access_token, refreshToken: s.refresh_token, expiresAt: s.expires_at ?? null } : null;

// Phone: Sign in with Apple with a hashed nonce, then { idToken, nonce } (the raw nonce).
async function authApple(b: Json) {
  const { idToken, nonce } = b as { idToken: string; nonce?: string };
  if (!idToken) return bad("idToken required");
  const { data, error } = await publicClient().auth.signInWithIdToken({ provider: "apple", token: idToken, nonce });
  if (error || !data.session || !data.user) return bad(error?.message ?? "sign in failed", 401);
  const credits = await ensureAccount(data.user);
  return json({ session: sessionJson(data.session), credits, freeSends: FREE_SENDS });
}

async function authRefresh(b: Json) {
  const { refreshToken } = b as { refreshToken: string };
  if (!refreshToken) return bad("refreshToken required");
  const { data, error } = await publicClient().auth.refreshSession({ refresh_token: refreshToken });
  if (error || !data.session) return bad("invalid_session", 401);
  return json({ session: sessionJson(data.session) });
}

async function creditsBalance(user: User | null) {
  if (!user) return bad("sign_in_required", 401);
  return json({ credits: await ensureAccount(user), freeSends: FREE_SENDS });
}

// ── Anthropic proxy ──────────────────────────────────────────────────────────
// The phone sends the same body it used to send directly; we add the key.
async function aiMessages(body: Json) {
  const r = await fetch(providers.anthropic.url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env("ANTHROPIC_API_KEY"),
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
  });
  return new Response(await r.text(), {
    status: r.status,
    headers: { "content-type": "application/json" },
  });
}

// ── DocuSeal ────────────────────────────────────────────────────────────────
//
// One submission per contract, one submitter per signature box (role = the
// box's party, e.g. "Freelancer"). Two ways each submitter signs:
//   • in Handshake: Face ID, then the phone calls /docuseal/complete, which
//     marks the submitter completed ("auto-signed via API") with the
//     signature image and the evidence the phone collected;
//   • in a browser: DocuSeal's own signing page (`url`, the submitter's
//     embed_src), typed or drawn — the option on the link page.
// The PDF carries DocuSeal text tags where the boxes are
// ({{Freelancer Signature;role=Freelancer;type=signature}}), so the fields
// land where the contract has them. No emails or texts from DocuSeal:
// Handshake delivers the links itself.
//
// start    → { id, submitters: [{ id, role, slug, url }] }
// complete → DocuSeal's submitter object
// status   → { status, submitters: [{ id, role, name, status, completedAt }],
//              documents: [{ name, url }], auditLogUrl }

const docuseal = (path: string, init: RequestInit = {}) =>
  fetch(`${providers.docuseal.url}${path}`, {
    ...init,
    headers: { "content-type": "application/json", "X-Auth-Token": env("DOCUSEAL_API_KEY"), ...(init.headers ?? {}) },
  });

type Submitter = { role: string; name?: string; email?: string; phone?: string };

async function docusealStart(b: Json, user: User | null) {
  const { title, pdfBase64, submitters, contractId } = b as {
    title: string; pdfBase64: string; submitters: Submitter[];
    /** The app's id for the contract: sending it again is free for a few sends. */
    contractId?: string;
  };
  if (!title || !pdfBase64 || !submitters?.length) return bad("title, pdfBase64, submitters required");

  // A send credit first. Signed out: refused once credits are enforced,
  // otherwise let through uncharged (see "Accounts and send credits").
  let charge: { contract: string; charged: boolean; credits: number } | null = null;
  if (user) {
    if (!contractId) return bad("contractId required");
    await ensureAccount(user);
    const { data, error } = await admin().rpc("begin_send", {
      p_user: user.id, p_contract: contractId, p_sends_per_credit: SENDS_PER_CREDIT,
    });
    if (error?.message.includes("no_credits")) return json({ error: "no_credits", credits: 0 }, 402);
    if (error) throw new Error(error.message);
    const row = (data as { charged: boolean; credits: number }[])[0];
    charge = { contract: contractId, charged: row.charged, credits: row.credits };
  } else if (enforceCredits()) {
    return bad("sign_in_required", 401);
  }

  // The send didn't happen: give the credit back.
  const undo = async () => {
    if (!charge || !user) return;
    await admin().rpc("undo_send", { p_user: user.id, p_contract: charge.contract, p_charged: charge.charged });
  };

  let r: Response;
  try {
    r = await docuseal("/submissions/pdf", {
      method: "POST",
      body: JSON.stringify({
        name: title,
        send_email: false,
        send_sms: false,
        order: "random",                       // anyone can sign first
        documents: [{ name: `${title}.pdf`, file: pdfBase64 }],
        submitters: submitters.map((s) => ({
          role: s.role,
          ...(s.name ? { name: s.name } : {}),
          ...(s.email ? { email: s.email } : {}),
          ...(s.phone ? { phone: s.phone } : {}),
          send_email: false,
          send_sms: false,
        })),
      }),
    });
  } catch (e) {
    await undo();
    throw e;
  }
  const text = await r.text();
  if (!r.ok) {
    await undo();
    return new Response(text, { status: r.status, headers: { "content-type": "application/json" } });
  }

  // The create call answers with the submission (or, on some accounts, the
  // bare submitter array) — accept both.
  let data;
  try { data = JSON.parse(text); } catch { data = {}; }
  const list: Json[] = Array.isArray(data) ? data : (data.submitters ?? []);
  const id = Array.isArray(data) ? list[0]?.submission_id : data.id;
  if (!id || !list.length) {
    await undo();
    return bad("DocuSeal answered without a submission", 502);
  }
  return json({
    id,
    submitters: list.map((s) => ({ id: s.id, role: s.role, slug: s.slug, url: s.embed_src ?? `https://docuseal.com/s/${s.slug}` })),
    ...(charge ? { credits: charge.credits, charged: charge.charged } : {}),
  });
}

async function docusealComplete(b: Json) {
  const { submitterId, signerName, role, signatureImage, signedDate, evidence } = b as {
    submitterId: number | string;
    signerName: string;
    role?: string;
    /** PNG, base64, of the signature as Handshake draws it. */
    signatureImage?: string;
    /** yyyy-mm-dd, for the box's date field when it has one. */
    signedDate?: string;
    // What the phone knows at the moment of the Face ID tap. Passed through so
    // it lands in the provider's record, not only on the device.
    evidence: { signedAt: string; deviceId: string; signatureHash: string; consentText: string };
  };
  if (!submitterId || !signerName) return bad("submitterId, signerName required");

  const fields: Json[] = [];
  if (role && signatureImage) fields.push({ name: `${role} Signature`, default_value: signatureImage });
  if (role && signedDate) fields.push({ name: `${role} Date`, default_value: signedDate });

  const r = await docuseal(`/submitters/${submitterId}`, {
    method: "PUT",
    body: JSON.stringify({
      name: signerName,
      completed: true,                       // "mark submitter as completed and auto-signed via API"
      send_email: false,
      ...(fields.length ? { fields } : {}),
      metadata: { ...evidence, method: "Face ID in Handshake" },
    }),
  });
  return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
}

async function docusealStatus(b: Json) {
  const { submissionId } = b as { submissionId: number | string };
  if (!submissionId) return bad("submissionId required");
  const r = await docuseal(`/submissions/${submissionId}`);
  const text = await r.text();
  if (!r.ok) return new Response(text, { status: r.status, headers: { "content-type": "application/json" } });
  const s = JSON.parse(text);
  return json({
    status: s.status,
    submitters: (s.submitters ?? []).map((x: Json) => ({
      id: x.id, role: x.role, name: x.name, status: x.status, completedAt: x.completed_at,
    })),
    documents: (s.documents ?? []).map((d: Json) => ({ name: d.name, url: d.url })),
    auditLogUrl: s.audit_log_url ?? null,
  });
}

// ── SignWell — Path B: Face ID unlocks SignWell's own signing screen ────────
//
// start: create the document with embedded signing on; SignWell returns an
//        embedded_signing_url per recipient that the phone loads in a WKWebView.
async function signwellStart(b: Json) {
  const { title, pdfBase64, recipients } = b as {
    title: string; pdfBase64: string; recipients: { name: string; email: string }[];
  };
  if (!title || !pdfBase64 || !recipients?.length) return bad("title, pdfBase64, recipients required");

  const r = await fetch(`${providers.signwell.url}/documents`, {
    method: "POST",
    headers: { "content-type": "application/json", "X-Api-Key": env("SIGNWELL_API_KEY") },
    body: JSON.stringify({
      test_mode: providers.signwell.testMode,
      name: title,
      embedded_signing: true,
      draft: false,
      files: [{ name: `${title}.pdf`, file_base64: pdfBase64 }],
      recipients: recipients.map((rcp, i) => ({
        id: `r${i + 1}`,
        name: rcp.name,
        email: rcp.email,
      })),
    }),
  });
  return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
}

async function signwellStatus(b: Json) {
  const { documentId } = b as { documentId: string };
  if (!documentId) return bad("documentId required");
  const r = await fetch(`${providers.signwell.url}/documents/${documentId}`, {
    headers: { "X-Api-Key": env("SIGNWELL_API_KEY") },
  });
  return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
}

// ── Router ───────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method !== "POST") return bad("POST only", 405);
  const path = new URL(req.url).pathname.replace(/^\/handshake/, "");
  let body: Json;
  try { body = await req.json(); } catch { return bad("invalid JSON"); }

  try {
    switch (path) {
      case "/ai/messages":       return await aiMessages(body);
      case "/auth/apple":        return await authApple(body);
      case "/auth/refresh":      return await authRefresh(body);
      case "/credits/balance":   return await creditsBalance(await caller(req));
      case "/docuseal/start":    return await docusealStart(body, await caller(req));
      case "/docuseal/complete": return await docusealComplete(body);
      case "/docuseal/status":   return await docusealStatus(body);
      case "/signwell/start":    return await signwellStart(body);
      case "/signwell/status":   return await signwellStatus(body);
      default:                   return bad(`no route ${path}`, 404);
    }
  } catch (e) {
    if (e instanceof Refusal) return e.response;
    return json({ error: (e as Error).message }, 500);
  }
});
