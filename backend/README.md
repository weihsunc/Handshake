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
| `POST /auth/apple` | `{idToken, nonce}` (Sign in with Apple; the raw nonce) → `{session:{accessToken,refreshToken,expiresAt}, credits, freeSends}`. Makes the account and gives the free sends the first time |
| `POST /auth/refresh` | `{refreshToken}` → `{session}`; 401 `invalid_session` when it can't be renewed |
| `POST /credits/balance` | signed in → `{credits, freeSends}`; signed out → 401 `sign_in_required` |
| `POST /docuseal/start` | `{contractId, title, pdfBase64, submitters:[{role,name,email,phone}]}` → `{id, submitters:[{id,role,slug,url}], credits, charged}`. Signed in: takes a send credit first (402 `no_credits` when none are left) and gives it back if DocuSeal fails. No emails or texts from DocuSeal |
| `POST /docuseal/complete` | `{submitterId, signerName, role, signatureImage, signedDate, evidence}` → marks the submitter completed ("auto-signed via API") |
| `POST /docuseal/status` | `{submissionId}` → `{status, submitters:[{id,role,name,status,completedAt}], documents, auditLogUrl}` |
| `POST /signwell/start`, `/signwell/status` | Path B, not used by the DocuSeal plan |

## Send credits (Nov 11, 2026)

Pricing (owner): **2 free sends per Apple ID, then $2.99 a send.** Only the
sender pays; signing is always free. One credit pays for one contract however
many people sign it, and sending the same contract again (after Revise
Contract) is free up to 5 sends in all; the 6th takes a new credit.

- **Accounts** are Supabase Auth users made from Sign in with Apple. The app
  sends Apple's identity token to `/auth/apple` (the function signs in with
  it and makes the account), keeps the session in the Keychain
  (`SendCredits.swift`) and sends `Authorization: Bearer <access token>` on
  every call.
- **Balances** live in Postgres (`migrations/20261111120000_send_credits.sql`):
  `accounts` (sends left), `credit_ledger` (every change), `free_grants`
  (a hash of the Apple ID, so deleting and remaking an account doesn't give
  the free sends again), `contract_sends` (the free re-sends). Row level
  security is on with no policies and the functions are service-role only,
  so nothing but this function can read or change a balance.
- **The charge** happens in `/docuseal/start`, in one locked transaction per
  account, so two quick sends can't both spend the last credit. A failed
  DocuSeal call gives the credit back.
- **`ENFORCE_CREDITS`** (secret, off by default): when `true`, `/docuseal/start`
  refuses callers who aren't signed in (401 `sign_in_required`; the app then
  shows Sign in with Apple). Until then signed-in callers are charged and
  everyone else goes through uncharged, so builds that can't use Sign in with
  Apple (Personal Team) keep working. Turn it on once the app with Sign in
  with Apple is what people use.

**Owner setup before it works live** (none of this is done yet):

1. Apply the migration: `supabase db push` from `backend/` (or let the GitHub
   integration do it, if it's set to run migrations).
2. Supabase dashboard → Authentication → Sign In / Providers → **Apple** →
   enable, **Client IDs** `com.weihsun.Handshake`. No secret key is needed
   for sign-in from the app. Needs the Sign in with Apple capability on the
   App ID, so it waits on the Apple Developer account.
3. When ready to require accounts: `supabase secrets set ENFORCE_CREDITS=true`.

**Tested locally (Nov 11):** a scratch Supabase stack with a stand-in DocuSeal.
Covered: 2 free sends, no extra grant on later calls, charge, free re-send,
the 6th re-send charging, refund on DocuSeal failure, 402 at zero, 5 sends at
once with 1 credit (exactly one goes), signed-out pass-through and
enforcement, bad and refreshed sessions, one free grant per Apple ID, and the
app's public key locked out of the tables and functions. **Not tested:** a
real Apple identity token through `/auth/apple` (needs the Apple account).

**Not built yet:** buying sends (StoreKit consumables, checked on the server
with Apple, added once per transaction — the ledger's unique index is
ready), giving a credit back when a contract is declined or cancelled before
anyone else signs, a daily limit on AI drafting, and DeviceCheck to cap free
sends per phone.

## Verified end to end (Nov 11, 2026)

Send with three signers → sender's part completed at send → one signer in a
browser (DocuSeal page) → another in the app with Face ID → DocuSeal reports
the submission completed → the sender's copy turns Signed when Contracts
opens.

Still worth checking: how the text tags size the fields on a long, real
contract PDF.

**Known gap:** the function is deployed without the gateway's JWT check
(`--no-verify-jwt`) — it checks sessions itself for credits, but the AI
proxy and the other DocuSeal routes are open to anyone with the URL. Fine
for testing; add an app check (App Attest) before launch.
