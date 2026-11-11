// GET /api/links/<id> — the encrypted contents of one short link, for the
// link page to decrypt with the key from its own URL. Unreadable without it.

export async function onRequestGet({ params, env }) {
  const id = String(params.id || "");
  if (!env.LINKS || !/^[A-Za-z0-9_-]{12}$/.test(id)) return notFound();
  const data = await env.LINKS.get(id, { type: "arrayBuffer" });
  if (!data) return notFound();
  return new Response(data, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Cache-Control": "public, max-age=86400",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex",
    },
  });
}

function notFound() {
  return new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
}
