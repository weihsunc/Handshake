// ─────────────────────────────────────────────────────────────────────────────
// Handshake backend — one Supabase Edge Function, four jobs.
//
// Why this exists: the iOS app must never hold an API key (HANDOFF §9). Every
// key lives here as a Supabase secret and the phone talks only to this URL.
//
// Routes (all POST, JSON in / JSON out):
//   /ai/messages          → Anthropic Messages API proxy (moves the key off the phone)
//   /docuseal/start       → create a DocuSeal submission for a contract (Path A)
//   /docuseal/complete    → after Face ID on the phone: mark the submitter signed
//   /signwell/start       → create a SignWell document, return an embedded signing URL (Path B)
//   /signwell/status      → poll completion (or wire the webhook later)
//
// Deploy (once you have a Supabase project):
//   supabase secrets set ANTHROPIC_API_KEY=... DOCUSEAL_API_KEY=... SIGNWELL_API_KEY=...
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

// ── DocuSeal — Path A: the phone's Face ID tap IS the signature ─────────────
//
// start: upload the contract as a PDF, one submitter per recipient, no emails
//        (Handshake already delivers the link itself). Returns submitter ids.
// complete: the documented "auto-signed via API" call — PUT /submitters/{id}
//        with completed:true plus the evidence Handshake collected.
async function docusealStart(b: Json) {
  const { title, pdfBase64, recipients } = b as {
    title: string; pdfBase64: string; recipients: { name: string; email: string }[];
  };
  if (!title || !pdfBase64 || !recipients?.length) return bad("title, pdfBase64, recipients required");

  const r = await fetch(`${providers.docuseal.url}/submissions/pdf`, {
    method: "POST",
    headers: { "content-type": "application/json", "X-Auth-Token": env("DOCUSEAL_API_KEY") },
    body: JSON.stringify({
      name: title,
      send_email: false,
      documents: [{ name: `${title}.pdf`, file: pdfBase64 }],
      submitters: recipients.map((rcp, i) => ({
        role: `Signer ${i + 1}`,
        name: rcp.name,
        email: rcp.email,
      })),
    }),
  });
  return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
}

async function docusealComplete(b: Json) {
  const { submitterId, signerName, evidence } = b as {
    submitterId: number | string;
    signerName: string;
    // What the phone knows at the moment of the Face ID tap. Passed through so
    // it lands in the provider's record, not only on the device.
    evidence: { signedAt: string; deviceId: string; signatureHash: string; consentText: string };
  };
  if (!submitterId || !signerName) return bad("submitterId, signerName required");

  const r = await fetch(`${providers.docuseal.url}/submitters/${submitterId}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "X-Auth-Token": env("DOCUSEAL_API_KEY") },
    body: JSON.stringify({
      name: signerName,
      completed: true,                       // "mark submitter as completed and auto-signed via API"
      send_email: false,
      metadata: evidence,
    }),
  });
  return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
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
      case "/signwell/start":    return await signwellStart(body);
      case "/signwell/status":   return await signwellStatus(body);
      default:                   return bad(`no route ${path}`, 404);
    }
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
