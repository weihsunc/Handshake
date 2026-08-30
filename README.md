# Handshake

A native iOS app that turns a plain-English prompt into a formatted contract, lets you edit it like Apple Notes, and sends it to recipients who sign with Face ID.

**Prompt → AI generates the contract → edit inline → send → recipient signs with Face ID → archived in history.**

SwiftUI, iOS 26, Anthropic Messages API. No backend.

---

## ⚠️ The signature is not legally binding

Read this before using Handshake for anything real.

iOS never exposes biometric data — `LocalAuthentication` returns pass/fail and nothing else. So the "Face ID signature" here is:

> Face ID authentication success **+** `SHA256(signerName + contractID + timestamp + deviceID)`

That gives you **authentication** (the device owner was present) and **tamper-evidence** (the document hash won't match if the text changes). It does **not** give you an independent chain of custody. If a signature is disputed, there is no third-party record of it — the proof lives only on the device that produced it.

This is a demo-grade signature, not a compliance-grade one. For legal enforceability you'd layer in a server that stores the cryptographic proof, or hand signing off to a certified provider like DocuSign. The reasoning behind that trade-off is in [`HANDOFF.md`](HANDOFF.md) §8.

Nothing in the app's UI claims otherwise, and it shouldn't be changed to.

---

## Running it

1. Open `Handshake.xcodeproj` in Xcode 26+
2. Add your Anthropic API key:
   ```bash
   cp Handshake/Secrets.example.swift Handshake/Secrets.swift
   ```
   then uncomment the enum and paste your key from [console.anthropic.com](https://console.anthropic.com).
3. Set your own team in **Signing & Capabilities** — the committed project file carries the original author's team ID.
4. Build to a simulator or device.

`Secrets.swift` is gitignored. Note that an API key shipped in an iOS binary is extractable by anyone who downloads the app — for anything beyond local development the key belongs server-side.

**Face ID on the simulator:** enroll via *Features → Face ID → Enrolled*, then *Matching Face* when the prompt appears.

---

## What's built

- **Home** — prompt bar with five contract templates
- **Workspace** — the contract document with a draggable AI chat panel that stays accessible while you read, plus an Apple Notes-style rich text editor (bold/italic/underline, headings, lists, alignment, inline photos, file attachments, signature placeholders)
- **Send flow** — recipient entry, SMS/Mail compose, each carrying a `handshake://sign/<uuid>` link
- **Signing** — read-only contract, Face ID auth, a stamped signature block, and a confirmation screen
- **History + persistence** — contracts stored as JSON in Application Support, grouped into Pending Signature / Signed / Drafts, with rich-text edits preserved as RTFD

## Architecture

[`HANDOFF.md`](HANDOFF.md) is the real documentation — full file map, the technical decisions worth not re-litigating, and the gotchas that cost debugging time. A few worth knowing up front:

- **The AI panel is a custom `ZStack` layer, not a `.sheet`.** Anything inside a `UISheetPresentationController` moves when the sheet is dragged, including the chat bar, which must stay fixed.
- **The text view is always `isEditable = true`.** Gating it on an `isEditing` flag deadlocks — UIKit never fires `textViewDidBeginEditing` on a non-editable text view, so the flag can never flip.
- **The signature block renders at `ImageRenderer.scale = 1`.** RTFD's importer sizes attachments by pixel dimensions, so a Retina-scale render comes back 3× oversized after a round-trip through history.

## Known limitations

Tracked in [`HANDOFF.md`](HANDOFF.md) §9. The notable ones: inline photos aren't persisted outside the attributed string, numbered lists restart at 1 on each application, contracts are local-only so a signing link only opens on the device that created it, and there's no error state for malformed AI output.

## License

MIT — see [LICENSE](LICENSE).
