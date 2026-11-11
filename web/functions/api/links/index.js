// POST /api/links — stores one short link's encrypted contents.
//
// The body is AES-256-GCM ciphertext made by the app (nonce ‖ ciphertext ‖
// tag, see Handshake/ShortLinks.swift). The key never comes here: it stays
// after the "#" in the link. Returns {"id"} — 12 random URL-safe characters.
//
// Storage: the KV namespace bound to this Pages project as LINKS. Entries
// expire after a year.

const MAX_BYTES = 256 * 1024;
const TTL_SECONDS = 60 * 60 * 24 * 365;

export async function onRequestPost({ request, env }) {
  if (!env.LINKS) return json({ error: "Link storage isn't set up" }, 503);
  const declared = Number(request.headers.get("content-length") || 0);
  if (declared > MAX_BYTES) return json({ error: "Too large" }, 413);

  const body = await request.arrayBuffer();
  // 12-byte nonce + 16-byte tag + at least one byte.
  if (body.byteLength < 29 || body.byteLength > MAX_BYTES) return json({ error: "Bad size" }, 400);

  const id = newId();
  await env.LINKS.put(id, body, { expirationTtl: TTL_SECONDS });
  return json({ id }, 201);
}

// 9 random bytes → 12 base64url characters (72 bits).
function newId() {
  const b = crypto.getRandomValues(new Uint8Array(9));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_");
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" },
  });
}
