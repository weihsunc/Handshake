# Handshake backend

One Supabase Edge Function. It exists so the iOS app never holds an API key:
the Anthropic key (AI drafting) and the DocuSeal key (signing records and the
browser signing option) live here as Supabase secrets.

## First-time setup

**Owner** (accounts and keys — only you can do these):

1. **DocuSeal** — sign up at docuseal.com (wei@studiolofi.com). Settings → API →
   copy the **test** key (it ends in `+test`).
2. **Supabase** — create a project called `handshake` in your account. Keep the
   database password it asks for.
3. In Terminal: `supabase login` (opens the browser to sign in).
4. From this `backend/` folder, paste your keys yourself:

   ```bash
   supabase secrets set ANTHROPIC_API_KEY=sk-ant-... DOCUSEAL_API_KEY=...+test
   ```

**Then** (Claude or you):

```bash
supabase link --project-ref <your-project-ref>
supabase functions deploy handshake --no-verify-jwt
```

The deploy prints `https://<ref>.supabase.co/functions/v1/handshake`. In
`Handshake/Secrets.swift` set `backendURL` to it and
`signingBackend = .docuseal`. Setting `backendURL` sends **all** AI calls
through the function, so the Anthropic key must be set there first.

SignWell (Path B, `SIGNWELL_API_KEY`) isn't needed for the DocuSeal plan.

## Live project (Nov 11, 2026)

- Supabase project **handshake** in the free
  **Handshake** organization; move it into Lofi Studio (Pro) when upgrading
  (project Settings → General → Transfer project). Free projects pause after
  about a week unused — un-pause from the dashboard.
- The function URL lives only in the gitignored `Secrets.swift` (and the
  Supabase dashboard). Keep it out of this public repo until the function
  has an app check. Secrets set: `ANTHROPIC_API_KEY`, `DOCUSEAL_API_KEY` (test).
- `supabase/config.toml` keeps `verify_jwt = false` for the function, so a
  deploy from the GitHub integration matches `--no-verify-jwt`.
- Verified live: AI proxy; DocuSeal start (text tags became fields),
  complete (base64 PNG accepted as the signature image), status.

## How signing works with DocuSeal on

1. **Send:** the app creates one DocuSeal submission (`/docuseal/start`) — a
   submitter per signature box, the PDF tagged so each box becomes that
   party's signature field. The sender, who signed with Face ID first, is
   completed straight away (`/docuseal/complete`).
2. **Each message** carries the app link (with that signer's DocuSeal part
   inside) and **"Don't have Handshake? Sign in your browser instead"** — the
   signer's DocuSeal page. Once the link page is hosted (`Config.linkPageURL`),
   there's one link and the page offers both.
3. **In the app:** Face ID, then `/docuseal/complete` for that signer, with the
   signature drawn in the Handshake typeface and the evidence. The signed copy
   still goes back to the sender as before.
4. **In a browser:** DocuSeal's page, typed or drawn signature.
5. **Sender's phone:** opening Contracts (or the app) asks `/docuseal/status`;
   anyone who signed in a browser is marked signed. When every box is signed,
   the contract moves to Signed.

## Routes

| Route | What it does |
|---|---|
| `POST /ai/messages` | Anthropic proxy — the app's generation and suggestions |
| `POST /docuseal/start` | `{title, pdfBase64, submitters:[{role,name,email,phone}]}` → `{id, submitters:[{id,role,slug,url}]}`. No emails or texts from DocuSeal |
| `POST /docuseal/complete` | `{submitterId, signerName, role, signatureImage, signedDate, evidence}` → marks the submitter completed ("auto-signed via API") |
| `POST /docuseal/status` | `{submissionId}` → `{status, submitters:[{id,role,name,status,completedAt}], documents, auditLogUrl}` |
| `POST /signwell/start`, `/signwell/status` | Path B, not used by the DocuSeal plan |

## Still to verify

The full app round trip (send → sign in the app and in a browser → the
sender's copy turns Signed), and how the text tags size the fields on a
real contract PDF.

**Known gap:** the function is deployed without auth (`--no-verify-jwt`), so
anyone with its URL can call it. Fine for testing; add an app check before
launch.
