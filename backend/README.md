# Handshake backend

One Supabase Edge Function. It exists so the iOS app never holds an API key.

## First-time setup (about ten minutes)

1. **Supabase** — create a free project at supabase.com. Install the CLI:
   `brew install supabase/tap/supabase`, then `supabase login` and
   `supabase link --project-ref <your-project-ref>` from this `backend/` folder.
2. **DocuSeal** — free sandbox at docuseal.com (no card). Profile → API key.
   The test key ends in `+test`.
3. **SignWell** — free account at signwell.com. Settings → API → create key.
   Test mode is unlimited; the first 25 real documents a month are free.

Then, from `backend/`:

```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-... DOCUSEAL_API_KEY=...+test SIGNWELL_API_KEY=...
supabase functions deploy handshake --no-verify-jwt
```

The deploy prints a URL like `https://<ref>.supabase.co/functions/v1/handshake`.
Paste that into `Handshake/Secrets.swift` as `backendURL` — it is the only
"secret" the app ships, and it isn't one.

## Routes

| Route | Path | What it does |
|---|---|---|
| `POST /ai/messages` | both | Anthropic proxy — the app's generation and suggestions go through here |
| `POST /docuseal/start` | A | Create a submission for a contract, one submitter per recipient, no emails |
| `POST /docuseal/complete` | A | After Face ID: mark the submitter completed ("auto-signed via API") with the evidence the phone collected |
| `POST /signwell/start` | B | Create a document with embedded signing; returns a signing URL per recipient |
| `POST /signwell/status` | B | Poll for completion |

Both providers start in **test mode**. Nothing here produces a real signature
until you switch them.
