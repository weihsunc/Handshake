// ─────────────────────────────────────────────────────────────────────────────
// Handshake backend — one Supabase Edge Function, four jobs.
//
// Why this exists: the iOS app must never hold an API key (HANDOFF §9). Every
// key lives here as a Supabase secret and the phone talks only to this URL.
//
// Routes (all POST, JSON in / JSON out):
//   /ai/messages          → Anthropic Messages API proxy (moves the key off the phone)
//   /docuseal/start       → create a DocuSeal submission for a contract, one submitter per box
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

const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`Missing secret ${k}`);
  return v;
};

const providers = {
  anthropic: { url: "https://api.anthropic.com/v1/messages" },
  docuseal:  { url: "https://api.docuseal.com" },                 // test key ends in "+test"
  signwell:  { url: "https://www.signwell.com/api/v1", testMode: true },
};

type Json = Record<string, unknown>;

const json = (body: Json, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const bad = (msg: string, status = 400) => json({ error: msg }, status);

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

async function docusealStart(b: Json) {
  const { title, pdfBase64, submitters } = b as { title: string; pdfBase64: string; submitters: Submitter[] };
  if (!title || !pdfBase64 || !submitters?.length) return bad("title, pdfBase64, submitters required");

  const r = await docuseal("/submissions/pdf", {
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
  const text = await r.text();
  if (!r.ok) return new Response(text, { status: r.status, headers: { "content-type": "application/json" } });

  // The create call answers with the submission (or, on some accounts, the
  // bare submitter array) — accept both.
  const data = JSON.parse(text);
  const list: Json[] = Array.isArray(data) ? data : (data.submitters ?? []);
  const id = Array.isArray(data) ? list[0]?.submission_id : data.id;
  return json({
    id,
    submitters: list.map((s) => ({ id: s.id, role: s.role, slug: s.slug, url: s.embed_src ?? `https://docuseal.com/s/${s.slug}` })),
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
      case "/docuseal/start":    return await docusealStart(body);
      case "/docuseal/complete": return await docusealComplete(body);
      case "/docuseal/status":   return await docusealStatus(body);
      case "/signwell/start":    return await signwellStart(body);
      case "/signwell/status":   return await signwellStatus(body);
      default:                   return bad(`no route ${path}`, 404);
    }
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
