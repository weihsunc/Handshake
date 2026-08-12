# Handshake — Project Handoff

**Last updated:** August 12, 2026
**Status:** Contract generation + editing complete. Send flow built. **Persistence + history built and compile-verified — see §0.** Signing not started.

---

## 0. August 12, 2026 Update — Persistence + History (Feature 1), compile-verified

Feature 1 from §7 was implemented in a cloud Cowork session without Xcode. It has now been built and partially verified on the simulator — **it compiled clean on the first try, no fixes were needed.**

**New files (project uses synchronized folders — they're picked up automatically):**

- `ContractStore.swift` — `@Observable` singleton, single source of truth. Persists all contracts to JSON at `Application Support/Handshake/contracts.json` (atomic write on every mutation, ISO-8601 dates). Queries: `drafts` / `pending` / `completed`. Mutations: `upsert`, `delete(id:)`, `markSent(id:recipients:)`, `markSigned(id:)`.
- `HistoryView.swift` — history sheet with sections **Pending Signature · Signed · Drafts**, `StatusBadge` (purple #4C00FF for pending, green signed, red declined, gray draft), swipe-to-delete on drafts, tap draft → reopens `ContractWorkspaceView`, tap sent/signed → `ReadOnlyContractView`. Also holds the `GeneratedContract.displayBody()` extension (RTFD wins over markdown).

**Changed files:**

- `Models.swift` — `GeneratedContract` and `Recipient` are now `Codable`. New fields on `GeneratedContract`: `bodyRTFD: Data?` (rich-text edits incl. inline images; takes precedence over `content` for display), `recipients`, `status: ContractStatus` (`draft/sent/signed/declined`), `createdAt`, `sentAt`, `signedAt`. All new fields have defaults, so existing `(id:title:content:)` call sites still compile.
- `ContractWorkspaceView.swift` — new optional `existing: GeneratedContract?` param: when set, loads the saved draft instead of generating (AI panel starts hidden). New `persist()` serializes the editor body to RTFD and upserts to the store; called after initial generation, after every AI update, when leaving edit mode, and `onDisappear`. **Two bug fixes:** AI follow-ups now keep the same contract `id` (previously every update minted a new UUID → would have duplicated drafts), and `persist()` re-reads status metadata from the store so closing the workspace can't regress a just-sent contract back to draft.
- `SendFlowView.swift` — tracks compose results; only when SMS/Mail actually reports sent does `finalize()` call `ContractStore.markSent` (recipients + timestamp), then dismisses. The `UIActivityViewController` fallback does *not* mark sent.
- `HomeView.swift` — hamburger button now opens `HistoryView` as a sheet.
- `ContractEditorView.swift` — `RichTextEditorImpl` gained `allowsEditing: Bool = true`; `false` is used only by the read-only viewer. Editable contexts must keep `true` (see the §6 gotcha — do not toggle `isEditable` for keyboard control).

**Verification checklist:**

1. ✅ **Build** — `** BUILD SUCCEEDED **`, zero errors, zero warnings. No compile fixes were needed.
2. ✅ **Generate → force-quit → relaunch → in Drafts** — a generated contract ("Freelance Web Development Services Agreement") was written to `contracts.json` with `status=draft` and survived a `simctl terminate` + relaunch.
3. ✅ **RTFD round-trip** — the draft reopened from history with bold runs, headings and section structure intact and no stray markdown asterisks (`bodyRTFD` = 12.7 KB). *Inline photos were not specifically exercised* — see the §9 caveat that attachments live only in the `NSAttributedString`.
4. ✅ **AI follow-up keeps one history entry** — exactly one Drafts row for the contract after AI updates. The `sendToAI()` fix (mutating the existing contract instead of adopting `result`'s new UUID) holds.
5. ⬜ **Send via Mail** — device-only; `MFMailComposeViewController` is unavailable on the simulator, so this cannot be verified here.
6. ✅ **Swipe-delete a draft** — swiped a draft, tapped Delete, force-quit, relaunched: gone from both the list and `contracts.json`.

Also confirmed: a seeded `contracts.json` decodes correctly (ISO-8601 dates) and renders all three sections with the right badges, recipient names, relative dates, and sort order.

**Verification tooling notes (environment, not app bugs):**

- The Claude simulator MCP *build* server can't read `Handshake/Assets.xcassets` (`actool` permission error, though the same command works from a normal shell). Build with `xcodebuild` directly. Its `control`/`attach` action works once Xcode is properly selected.
- `HomeView` carries a `#if DEBUG` launch-argument hook so History can be opened headlessly for screenshots, with no tap:
  ```
  xcrun simctl launch <udid> com.weihsun.Handshake -HandshakeOpenHistory
  ```
  Debug-only; safe to delete.

---

## 1. What Handshake Is

A native iOS app that turns a plain-English prompt into a legally formatted contract, lets you edit it like Apple Notes, then send it to recipients who sign with Face ID.

**Core loop:** Prompt → AI generates contract → Edit inline → Send to recipients → They sign with Face ID → Archived in history.

**Product bet:** The AI chat panel is the hero. It's always accessible, never hidden behind a modal — you can talk to it while looking at the contract.

---

## 2. Stack & Setup

| | |
|---|---|
| **Platform** | Native iOS 26, SwiftUI |
| **AI** | Anthropic Messages API, `claude-haiku-4-5-20251001` |
| **Persistence** | None yet (all in-memory) |
| **Backend** | None |
| **Min target** | iOS 26 (uses liquid-glass toolbar behavior) |

### Running it

1. Open `Handshake.xcodeproj` in Xcode
2. Put an Anthropic API key in `Config.swift` (`anthropicAPIKey`)
3. Build to simulator or device

> ⚠️ **Security:** A live API key is currently hardcoded in `Config.swift` and committed to git. **Rotate that key and remove it from history before sharing this repo.** For production, the key must move server-side — an API key shipped in an iOS binary is extractable by anyone who downloads the app.

---

## 3. File Map

| File | Lines | Status | Purpose |
|---|---|---|---|
| `HandshakeApp.swift` | 13 | ✅ Live | App entry, wraps `HomeView` in `NavigationStack` |
| `HomeView.swift` | 151 | ✅ Live | Landing screen — illustration, template cards, chat bar |
| `ContractWorkspaceView.swift` | 603 | ✅ Live | **The main screen.** Contract + AI panel + editor |
| `Components.swift` | 538 | ✅ Live | Shared UI: ChatBar, toolbars, buttons, illustration |
| `ContractEditorView.swift` | 489 | ⚠️ Mixed | `RichTextEditorImpl` + pickers + markdown parser are **live**; the `ContractEditorView` struct itself is **dead** |
| `SendFlowView.swift` | 334 | ✅ Live | Recipient entry + SMS/Mail compose |
| `AIService.swift` | 139 | ✅ Live | Anthropic API client, contract parsing |
| `Models.swift` | 27 | ✅ Live | `GeneratedContract`, `ChatMessage`, `Recipient` |
| `Config.swift` | 9 | ✅ Live | API key |
| `ChatSheetView.swift` | 194 | ❌ Dead | Superseded by `ContractWorkspaceView`. Safe to delete |

---

## 4. What's Built

### 4a. Home screen (`HomeView`)

- Handshake illustration + welcome copy as the empty state
- Tapping the chat bar swaps the illustration for a horizontal row of 5 template cards (Consulting, NDA, Rental, Employment, Partnership)
- Each template card fills the prompt and launches the workspace
- Chat bar is always pinned to the bottom
- Launches `ContractWorkspaceView` via `.fullScreenCover`

### 4b. Contract workspace (`ContractWorkspaceView`) — the core screen

This is where the real architectural work went. Layout is a `ZStack` with explicit z-ordering:

```
ZStack(alignment: .bottom)
  ├── Background                 zIndex 0
  ├── Contract scroll view       zIndex 0
  ├── Draggable AI panel         zIndex 1   ← snaps large ↔ medium ↔ dismissed
  └── Hero ChatBar               zIndex 2   ← NEVER moves
```

**The AI panel is a custom draggable view, not a UIKit sheet.** This was a deliberate rewrite (see §6).

- Drag the panel to snap between large (full content height), medium (46%), or flick down to dismiss
- The chat bar sits *above* the panel in the ZStack, so dragging never moves it
- Sending a message while the panel is dismissed re-opens it at medium

### 4c. Rich text editor (Apple Notes style)

Tap anywhere in the contract body to enter edit mode. Nav bar trailing button becomes **Done**. Changes auto-save on exit.

Formatting toolbar — one floating glass pill that scrolls horizontally, matching Figma node `2021-1799`:

| Group | Actions |
|---|---|
| Signature | Insert e-signature placeholder block (**first**, per design) |
| Text style | Bold, Italic, Underline |
| Headings | H1 (26pt bold), H2 (20pt bold) |
| Lists | Bullet (•), Numbered (1. 2. 3.) |
| Alignment | Left, Center, Right |
| Insert | Photo (inline `NSTextAttachment`), File attachment |

All formatting operates directly on `UITextView.textStorage` so the cursor never jumps.

### 4d. Send flow (`SendFlowView`)

- Add one or more recipients — name, email, phone
- Validation: needs a name + at least one contact method
- On send: opens `MFMessageComposeViewController` for phone recipients, then chains to `MFMailComposeViewController` for email recipients
- Falls back to `UIActivityViewController` on simulator (compose sheets are unavailable there)
- Message body includes a deep link stub: `handshake://sign/<contract-uuid>`

> The URL scheme is **not yet registered in Info.plist** — the link won't open the app until it is.

### 4e. AI service (`AIService`)

- `generateContract(for:)` — system prompt instructs Claude to return `TITLE: ...\n---\n<body>`, parsed into `GeneratedContract`
- `needsClarification(for:)` — heuristic checking word count + presence of parties/duration/amount signals
- `getClarification(for:)` — asks Claude for 2–3 follow-up questions
- Custom markdown parser converts `**bold**` to real bold runs with no visible asterisks

---

## 5. Data Models

```swift
struct GeneratedContract: Identifiable {
    let id: UUID
    var title: String
    var content: String
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
}

struct Recipient: Identifiable {
    let id: UUID
    var name:  String
    var email: String
    var phone: String
}
```

**None of these are `Codable` yet.** Adding persistence is the first task in the remaining work — everything else depends on it.

---

## 6. Key Technical Decisions & Gotchas

These cost real debugging time. Don't re-litigate them without reading first.

### The AI panel is not a UIKit sheet

Originally used `.sheet` with `PresentationDetent`. The problem: anything inside a `UISheetPresentationController` moves when the sheet is dragged — including the chat bar, which must stay fixed. Rebuilt as a plain `ZStack` layer with a custom `DragGesture` that snaps between heights. The chat bar is a sibling at a higher `zIndex`, so it's structurally incapable of moving.

### Panel height must come from `GeometryReader`, not `UIScreen`

`UIScreen.main.bounds.height` includes the nav bar and status bar, so the panel extended up behind the toolbar buttons. `NavigationStack` already excludes its own nav bar from the content area, so `geo.size.height` inside a `GeometryReader` is the correct measurement.

### The text view must always be `isEditable = true`

**This was a real bug.** The editor started with `isEditable = false` and only flipped to `true` when `isEditing` became `true` — but `isEditing` could only become `true` via `textViewDidBeginEditing`, which UIKit never fires on a non-editable text view. Circular deadlock; tapping did nothing.

Fix: keep `isEditable = true` always. Control the keyboard purely through `becomeFirstResponder` / `resignFirstResponder`. Never call `becomeFirstResponder` programmatically on tap — let UIKit handle it naturally.

### iOS 26 toolbar items get wrapped in a glass pill

Any `ToolbarItem` is wrapped in a 44pt liquid-glass container. A custom-styled view inside it gets clamped unless it *exactly* fills that 44pt container — otherwise the container's glass shows at the corners as a white ring.

We fought this for several rounds trying to make a purple circle send button. **Current state: reverted to a plain native button with a purple `arrow.up.right` icon.** Marked as "fix later." If you retry: mirror `GlassIconButton`'s exact geometry (36pt icon, 44pt height, 4pt horizontal padding, `Capsule` background) rather than using `Circle()` with a smaller frame.

### `ShareLink` doesn't work as a toolbar label

`UINavigationBar` clamps its intrinsic size to a small square. Use a plain `Button` + a state flag + `UIActivityViewController` (see `ActivityView` in `Components.swift`).

### Design tokens

```
Purple gradient   #4C00FF → #26065D, 112° (start 0.08,0 → end 1.47,1)
Background        #FAFAFA  (stone/50 in Figma is #FAFAF9)
Card background   #F4F4F5
Body text         SF Pro Regular 17 / 22, tracking -0.43
Title             SF Pro Bold 28 / 34, tracking 0.38
Secondary text    #757575
Pill radius       Capsule / 296px in Figma
Toolbar pill      h-48, px-10, shadow 0 8px 40px rgba(0,0,0,0.12)
```

---

## 7. Remaining Work

### Feature 1 — Persistence + Contract History

**Do this first.** Everything else depends on it.

1. Make `GeneratedContract` and `Recipient` conform to `Codable`
2. Add a `ContractStatus` enum: `draft | sent | signed | declined`
3. Extend `GeneratedContract` with `recipients: [Recipient]`, `status`, `sentAt`, `signedAt`
4. Build `ContractStore` — an `@Observable` singleton persisting to a JSON file in Application Support
5. Build the history screen:
   - Sections: **Pending Signature** · **Signed** · **Drafts**
   - Row: title, recipient names, relative date, status badge
   - Swipe-to-delete on drafts
   - Tap a draft → opens workspace in edit mode; tap a sent/signed one → read-only
6. Wire it to the hamburger menu button in `HomeView` (currently does nothing)

### Feature 2 — Wire up the send flow properly

Mostly built. Remaining:

1. Register the `handshake://` URL scheme in Info.plist
2. Handle the incoming deep link (`onOpenURL`) → route to the signing screen
3. On send, set `status = .sent` and persist

### Feature 3 — Face ID signing

**How this actually works:** iOS never exposes biometric data. `LocalAuthentication` returns only pass/fail. So a "face signature" is really:

> Face ID authentication success **+** a cryptographic stamp: `SHA256(recipientName + contractID + timestamp + deviceID)`

**Screens:**

1. **Signing screen** — read-only contract, "Sign with Face ID" purple pill at the bottom
2. **Auth** — `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`
3. **On success** — generate the hash via `CryptoKit`, replace the `[Signature]` placeholder with a `SignatureBlockView`: recipient name in a script-style face, "✓ Verified with Face ID" badge, ISO timestamp, and a short fingerprint of the hash
4. **Confirmation** — full-screen checkmark, `status = .signed`

---

## 8. The eSignature Decision

Three options were considered:

| Approach | Legally binding? | Cost | Effort |
|---|---|---|---|
| **A. On-device** (Face ID + CryptoKit) | ❌ No | Free | Low |
| **B. Third-party API** (DocuSign, Dropbox Sign) | ✅ Yes, 60+ countries | Per-envelope $ | High — signing happens in their webview, breaks the native Face ID concept |
| **C. Hybrid** — Face ID locally, proof stored on your backend | ⚠️ Stronger, not certified | Backend hosting | Medium |

**Decision: ship Option A now.** It delivers the full UX end-to-end, the Face ID + hash stamp is a real product differentiator, and it's the fastest path to a working demo.

**Migration path:** when legal enforceability matters, layer in Option C. The UX doesn't change at all — you just additionally write the cryptographic proof to a server for an auditable trail. Option B only becomes necessary if you need court-recognized certification.

> ⚠️ **Do not market this as legally binding in its current form.** On-device Face ID + a local hash gives you authentication and tamper-evidence, but no independent chain of custody. If a signature is disputed, there's no third-party record. This is a demo-grade signature, not a compliance-grade one.

---

## 9. Known Issues / Cleanup

- [ ] **Live API key committed to git** in `Config.swift` — rotate it, purge from history, move server-side
- [ ] `ChatSheetView.swift` is fully dead — delete the file
- [ ] The `ContractEditorView` struct is dead, but **don't delete the file** — it still holds `RichTextEditorImpl`, `PhotoPickerView`, `DocumentPickerView`, and the markdown parser. Extract those into their own files, then delete the struct
- [ ] Purple circle send button still shows a white ring from the iOS 26 glass container — currently reverted to a plain purple icon
- [ ] `handshake://` URL scheme not registered in Info.plist
- [ ] Numbered lists renumber from 1 on each application — no continuation logic
- [ ] Photo attachments live only in the `NSAttributedString`; they aren't persisted anywhere
- [ ] No error state if the AI returns malformed output (missing `TITLE:` / `---`)
- [ ] Xcode isn't available in the environment this was built in — **nothing here has been compile-verified.** Build before trusting it

---

## 10. If You're Porting This to Lovable (Web)

Lovable is React + TypeScript + Tailwind + Supabase. Most of this translates; two things don't.

**Translates cleanly:**
- All layout, design tokens, and the visual system
- The AI service — same Anthropic API, but call it from a Supabase edge function so the key stays server-side (which also fixes issue #1 above)
- Contract history — Supabase table instead of a local JSON file, which you want anyway
- Send flow — an email service (Resend, Postmark) instead of `MFMailComposeViewController`

**Doesn't translate:**

1. **Face ID.** There's no web equivalent. The closest is **WebAuthn / passkeys** — `navigator.credentials.get()` triggers the platform biometric prompt (Touch ID, Windows Hello, Android fingerprint) and returns a signed assertion. This is *better* than the iOS approach for your use case, because WebAuthn returns a real cryptographic signature backed by a hardware key, not just a pass/fail boolean. Worth considering even if you stay native.

2. **The rich text editor.** `UITextView` + `NSAttributedString` has no web analog. Use **TipTap** (ProseMirror) or **Lexical**. Both give you the Notes-style toolbar, inline images, and custom nodes — a custom node is exactly the right primitive for the signature block.

**Actually a strong argument for web:** the recipient signing flow. Right now a recipient has to install the app to sign, which is a brutal conversion funnel. On web they'd click a link and sign in the browser. A hybrid — native app for creating, web link for signing — is likely the better product regardless of which stack you pick.

---

## Appendix: Prompt for a New Session

> I'm building **Handshake**, a native iOS app (SwiftUI, iOS 26) that generates contracts from natural-language prompts using the Anthropic API, lets users edit them in an Apple Notes-style rich text editor, and sends them to recipients to sign with Face ID.
>
> Built so far: home screen with templates, the main contract workspace (draggable AI chat panel + rich text editor with a full formatting toolbar), and the send flow (recipient entry + SMS/Mail compose).
>
> Not built: persistence, contract history, and the Face ID signing flow.
>
> Read `HANDOFF.md` in the project root for full architecture, technical gotchas, and the remaining work plan. Start with Feature 1 (persistence + history) since everything else depends on it.
