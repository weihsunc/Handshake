# Handshake — Project Handoff

**Last updated:** September 12, 2026
**Status:** Full loop works end to end **across two devices** with no server — send → recipient opens on their own phone → signs with Face ID → signed copy returns to the sender (§0). Provider-backed signing scaffolded, awaiting accounts (§7 Feature 4). Remaining: the §9 list.

---

## 0. August 12, 2026 Update — Persistence + History (Feature 1), compile-verified

Feature 1 from §7 was implemented in a cloud Cowork session without Xcode. It has now been built and partially verified on the simulator — **it compiled clean on the first try, no fixes were needed.**

**New files (project uses synchronized folders — they're picked up automatically):**

- `ContractStore.swift` — `@Observable` singleton, single source of truth. Persists all contracts to JSON at `Application Support/Handshake/contracts.json` (atomic write on every mutation, ISO-8601 dates). Queries: `drafts` / `pending` / `completed`. Mutations: `upsert`, `delete(id:)`, `markSent(id:recipients:)`, `markSigned(id:signedBy:signatureHash:bodyRTFD:)`.
- `HistoryView.swift` — history sheet with sections **Pending Signature · Signed · Drafts**, `StatusBadge` (purple #4C00FF for pending, green signed, red declined, gray draft), swipe-to-delete on drafts, tap draft → reopens `ContractWorkspaceView`, tap sent/signed → `ReadOnlyContractView`. Also holds the `GeneratedContract.displayBody()` extension (RTFD wins over markdown).

**Changed files:**

- `Models.swift` — `GeneratedContract` and `Recipient` are now `Codable`. New fields on `GeneratedContract`: `bodyRTFD: Data?` (rich-text edits incl. inline images; takes precedence over `content` for display), `recipients`, `status: ContractStatus` (`draft/sent/signed/declined`), `createdAt`, `sentAt`, `signedAt`. All new fields have defaults, so existing `(id:title:content:)` call sites still compile.
- `ContractWorkspaceView.swift` — new optional `existing: GeneratedContract?` param: when set, loads the saved draft instead of generating (AI panel starts hidden). New `persist()` serializes the editor body to RTFD and upserts to the store; called after initial generation, after every AI update, when leaving edit mode, and `onDisappear`. **Two bug fixes:** AI follow-ups now keep the same contract `id` (previously every update minted a new UUID → would have duplicated drafts), and `persist()` re-reads status metadata from the store so closing the workspace can't regress a just-sent contract back to draft.
- `SendFlowView.swift` — tracks compose results; only when SMS/Mail actually reports sent does `finalize()` call `ContractStore.markSent` (recipients + timestamp), then dismisses. The `UIActivityViewController` fallback does *not* mark sent.
- `HomeView.swift` — hamburger button now opens `HistoryView` as a sheet.
- `RichTextEditor.swift` (then in `ContractEditorView.swift`) — `RichTextEditorImpl` gained `allowsEditing: Bool = true`; `false` is used only by the read-only viewer. Editable contexts must keep `true` (see the §6 gotcha — do not toggle `isEditable` for keyboard control).

**Verification checklist:**

1. ✅ **Build** — `** BUILD SUCCEEDED **`, zero errors, zero warnings. No compile fixes were needed.
2. ✅ **Generate → force-quit → relaunch → in Drafts** — a generated contract ("Freelance Web Development Services Agreement") was written to `contracts.json` with `status=draft` and survived a `simctl terminate` + relaunch.
3. ✅ **RTFD round-trip** — the draft reopened from history with bold runs, headings and section structure intact and no stray markdown asterisks (`bodyRTFD` = 12.7 KB). *Inline photos were not specifically exercised* — see the §9 caveat that attachments live only in the `NSAttributedString`.
4. ✅ **AI follow-up keeps one history entry** — exactly one Drafts row for the contract after AI updates. The `sendToAI()` fix (mutating the existing contract instead of adopting `result`'s new UUID) holds.
5. ⬜ **Send via Mail** — device-only; `MFMailComposeViewController` is unavailable on the simulator, so this cannot be verified here.
6. ✅ **Swipe-delete a draft** — swiped a draft, tapped Delete, force-quit, relaunched: gone from both the list and `contracts.json`.

Also confirmed: a seeded `contracts.json` decodes correctly (ISO-8601 dates) and renders all three sections with the right badges, recipient names, relative dates, and sort order.

**End-to-end pass (September 1, 2026):** the whole loop was walked on the simulator as one experience — home → template → generate → send → sign → history — and these breaks were found and fixed:

- **Template card icons rendered as `[?]` tofu.** Not app code: the **iOS 26.3 simulator runtime** fails to render colour emoji at all (the same build renders them fine on 26.5). The old `EmojiView` UILabel bridge that pinned `AppleColorEmoji` didn't help and was removed; the cards use plain `Text` now. **Verify on the 26.5 runtime or newer**, and expect tofu on 26.3.
- **Nav title showed the raw prompt cut mid-sentence** ("Create a contract for a") while generating. Now "New Agreement" until the AI returns a title.
- **The Send pill in the workspace toolbar rendered as "S / e" on two lines.** The iOS 26 glass container squeezes the item and wraps the label. `PurplePillButton` now has `lineLimit(1)` + `fixedSize(horizontal: true)`, which stops the wrap without changing the geometry §6 warns about.
- **The share-sheet fallback was a dead end.** It passed `[subject, body]` as two items, which iOS described as "2 Images", and on dismissal dropped the user back on the send form with no feedback and no status change. It now shares one combined string and, when a share *completes*, asks "Did you send it?" — marking sent only on an explicit yes, since the share sheet can't distinguish Mail from Copy. The §0 rule that the fallback never marks sent silently still holds.
- **A signing link arriving while the workspace was open was silently dropped.** The workspace is a `fullScreenCover` from `HomeView`; SwiftUI won't present `RootView`'s cover on top of it, so tapping "Open in Handshake" did nothing. `DeepLinkRouter.dismissAll()` now tells `HomeView` to close its cover and history sheet before `RootView` presents, ~400 ms later.
- **The workspace didn't reflect a contract being sent from inside it.** It now reads status live from the store: a Pending/Signed badge appears beside the title, and Send is replaced by the Signed badge once signed (editing a signed document would invalidate the stamp).

The full loop — draft → sent → signed, with signer, timestamp and hash persisted — now completes on the simulator with no device and no Mail account.

**Two-device pass (September 12, 2026):** sender on an iPhone 17 Pro, recipient on a **separate, empty** iPhone 17 (its store wiped first). Before the change, the recipient hit the "not on this device" alert — the link was just a UUID. After:

1. Sender's link (built by `SendFlowView` from the store, recipients included) opens on the empty recipient → contract stored locally, `SigningView` shows it with Pending badge, "Signing as" pre-filled from the payload.
2. Recipient signs with Face ID (real `LAContext`, simulated matching face) → `signed`, `signedBy`, `signedAt`, `signatureHash`, stamped RTFD all recorded on the recipient.
3. Recipient's History lists it under Signed.
4. The "Send signed copy back" link opens on the sender → sender's record moves to `signed` with the **same hash** the recipient produced; still exactly one entry; read-only viewer presented.

One detour worth knowing: restarting SpringBoard on a simulator (`launchctl kickstart -k system/com.apple.SpringBoard`) **wipes its Face ID enrollment**. The first sign attempt failed with "Biometry is not enrolled" — which the app surfaced as a clean alert, so that error path is verified too. Re-enroll with `notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` + `-p`.

**Verification tooling notes (environment, not app bugs):**

- The Claude simulator MCP *build* server can't read `Handshake/Assets.xcassets` (`actool` permission error, though the same command works from a normal shell). Build with `xcodebuild` directly. Its `control`/`attach` action works once Xcode is properly selected.
- `#if DEBUG` launch-argument hooks let a headless run drive flows the simulator panel can't tap (a second device it hasn't been granted, the system "Open in Handshake?" prompt):
  ```
  -HandshakeOpenHistory          open History on launch
  -HandshakeDumpPDF              write the newest contract's PDF to Application Support/Handshake/preview.pdf
  -HandshakeOpenURL '<url>'      feed a handshake:// URL to the router, bypassing the system prompt
  -HandshakeAutoSign             tap "Sign with Face ID" ~1 s after the signing screen appears
  ```
  The biometric prompt is still real; answer it with `notifyutil -p com.apple.BiometricKit_Sim.pearl.match`. Debug-only; safe to delete.

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
| **Persistence** | JSON file in Application Support (`ContractStore`) |
| **Backend** | Optional — one Supabase Edge Function in `backend/` that holds the API keys (Anthropic, DocuSeal, SignWell). Off until `Secrets.backendURL` is set |
| **Min target** | iOS 26 (uses liquid-glass toolbar behavior) |

### Running it

1. Open `Handshake.xcodeproj` in Xcode
2. `cp Handshake/Secrets.example.swift Handshake/Secrets.swift` and paste your Anthropic API key in
3. Build to simulator or device

> ⚠️ **Security:** `Secrets.swift` is gitignored, so the key stays out of git — but it is still compiled into the app binary and is extractable by anyone who downloads the app. For production the key must move server-side.

---

## 3. File Map

| File | Purpose |
|---|---|
| `HandshakeApp.swift` | App entry + `RootView` (deep-link routing, §4f) + `DeepLinkRouter` |
| `HomeView.swift` | Landing screen — illustration, template cards, chat bar |
| `ContractWorkspaceView.swift` | **The main screen.** Contract + AI panel + editor |
| `Components.swift` | Shared UI: ChatBar, toolbars, `GlassIconButton` / `ToolbarPillButton` (system glass) / `PurplePillButton` (custom, full-width only), illustration, `MessageBubble` |
| `RichTextEditor.swift` | `RichTextEditorImpl` — the `UITextView` ↔ SwiftUI bridge |
| `MarkdownParser.swift` | `NSMutableAttributedString.fromHandshakeMarkdown` |
| `ListNumbering.swift` | Pure Foundation: what number the next list item gets. Testable outside the app |
| `MediaPickers.swift` | `PhotoPickerView`, `DocumentPickerView` |
| `SendFlowView.swift` | Recipient entry + SMS/Mail compose |
| `SigningView.swift` | Recipient's signing screen + confirmation screen |
| `SignatureService.swift` | Face ID auth + CryptoKit SHA256 stamp |
| `SignatureBlockView.swift` | The signature block + stamping it into the document |
| `ContractStore.swift` | `@Observable` store, JSON persistence |
| `HistoryView.swift` | Contract history + `ReadOnlyContractView` |
| `AIService.swift` | Anthropic API client, contract parsing |
| `Models.swift` | `GeneratedContract`, `ChatMessage`, `Recipient`, `ContractStatus` |
| `Config.swift` | Forwards to `Secrets.swift` |
| `Secrets.swift` | **Gitignored.** The API key. Copy from `Secrets.example.swift` |
| `Info.plist` | *(repo root)* URL scheme + Face ID usage string |

`ChatSheetView.swift` and the `ContractEditorView` struct were deleted — both were dead. `MessageBubble` moved out of `ChatSheetView` into `Components.swift`, since the workspace's AI panel still uses it.

`BlackPillButton` in `Components.swift` is now unused — `ContractEditorView`'s Save button was its only caller. Left in place as part of the button set rather than deleted.

---

## 4. What's Built

### 4a. Home screen (`HomeView`) — Figma 2160:6597 / 2160:6694

One screen, three states, driven by the chat bar's focus and text:

| State | What shows | Tap on a card |
|---|---|---|
| **idle** | Illustration + welcome copy, then the example templates as a **vertical** list of full-width cards scrolling under the chat bar | Launches the workspace with that prompt |
| **focused** (empty) | Hero collapses; the cards pin to the top; the chat bar rides the keyboard | Launches the workspace |
| **typing** | Cards become **autocomplete suggestions**: 3 concrete contracts the model thinks you mean ("NDA" → *NDA for a new employee*, *Mutual NDA between two companies*, …), each with an emoji, a ≤6-word title and a ready-to-send prompt. Until the model answers, templates ranked by prefix/keyword match paint instantly | **Fills the prompt** so it can be edited, doesn't launch |

Implementation notes:

- The chat bar is a `.safeAreaInset(edge: .bottom)`, not a `ZStack` overlay — that's what makes the list scroll under it and makes it follow the keyboard for free.
- Collapsing the hero removes ~400pt above the cards but `ScrollView` keeps its offset, so the first card would slide up behind the toolbar. A `ScrollViewReader` scrolls to the cards whenever focus changes.
- `TemplateCard` is the Figma "Snackbar": stone/100 `#F5F5F4`, radius 24, 16pt padding, title with the emoji inline (`"📄 Consulting Agreement"` as one string), gray body. It fills its container's width; the list owns the horizontal inset.
- The chat bar placeholder is the brand gradient ("Start with HandShake"). A `TextField` can't style its placeholder, so a gradient `Text` is overlaid while the field is empty.
- Hero type follows the Figma frame (30pt semibold / 20pt regular, system font) rather than the older 28/17 tokens in §6.
- **AI suggestions** (`AIService.suggestPrompts`, haiku, `max_tokens` 300): fired ~450 ms after the last keystroke on ≥3 characters, cancelled by the next keystroke, cached per lowercased query, and skipped when the text is exactly a suggestion that was just tapped. The model returns `EMOJI | TITLE | PROMPT` lines; anything unparseable is dropped. On any failure the local ranking simply stays up — there's no error state, by design. The suggestions state isn't drawn in Figma (frame 18 shows typed text with the example cards); the 3-card layout reuses `TemplateCard`.

Launches `ContractWorkspaceView` via `.fullScreenCover`.

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

The `handshake://` scheme is registered (see §4f), so that link opens the app.

### 4f. Deep links (`RootView` in `HandshakeApp.swift`)

`handshake://sign/<contract-uuid>` opens the app straight to the signing screen.

- The scheme is registered in `Info.plist` at the **repo root**, not in `Handshake/`. That folder is a synchronized group, so a plist inside it also gets copied in as a bundle resource and collides with the generated one (`Multiple commands produce .../Handshake.app/Info.plist`). `GENERATE_INFOPLIST_FILE` stays `YES` and Xcode merges the generated keys into this file, so only `CFBundleURLTypes` lives there.
- `RootView.onOpenURL` resolves the URL to a route and presents `SigningView`.
- **The link carries the contract** (`ContractTransfer`): `handshake://sign/<uuid>?d=<base64url(zlib(JSON))>`. The payload is title, markdown body, recipients, status and timestamps — the RTFD is left out (≈10× the size; the recipient never edits), so a recipient sees the markdown rendering. An 8.8 KB contract becomes a ~4.9K-char link, which survives SMS, Mail and the share sheet. Opening it on a phone that has no copy stores one and presents `SigningView`; on the sender's own phone the local copy wins.
- **The signed copy comes back the same way**: `handshake://signed/<uuid>?d=…`. The confirmation screen offers "Send signed copy back", which shares a message with that link. Opening it on the sender's phone calls `markSigned` on their record (their RTFD edits are kept, only signer/hash/timestamp are taken) and shows the read-only viewer. No server anywhere — two phones and any messaging channel.
- Failure cases show an alert rather than failing silently: wrong host, malformed UUID, a `sign` link with no payload (an old-format link), a `signed` link whose payload isn't actually signed.
- A link arriving while *anything* is presented dismisses it first via `DeepLinkRouter.dismissAll()`. A live `fullScreenCover` swallows `.alert`, SwiftUI ignores a second `item:` change while the first is up, and — the case that actually bit — a cover presented from `HomeView` (the workspace) blocks `RootView` from presenting at all, so the link was silently dropped. `HomeView` observes `dismissTick` and drops its cover and history sheet; `RootView` presents ~400 ms later.

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

### iOS 26 toolbar items get wrapped in a glass pill — so don't paint your own

Any `ToolbarItem` is wrapped in a 44pt Liquid Glass capsule by the system. Painting a *second* capsule inside it (a `.regularMaterial` background, a purple gradient) gives you two stacked pills with slightly different geometry, and the system one peeks out as a seam or a pale ring. Several rounds were spent trying to make the custom pill exactly match the container. **That was the wrong fight.**

**Resolution:** toolbar buttons draw no background at all and let the system capsule be the pill.

- Icon buttons (`GlassIconButton`) are a bare `Button { Image }` — iOS renders a solid glass circle.
- The purple Send action in a toolbar is `ToolbarPillButton`: `.buttonStyle(.glassProminent)` + `.tint(#4C00FF)`. The system capsule *is* the filled pill, so there is nothing to ring. Cost: it's a flat tint rather than the §6 gradient, which only the system can draw there.
- `PurplePillButton` (custom gradient) is now only for full-width actions **outside** toolbars — the signing screen and confirmation — where there's no system container to fight.

### Don't branch a tappable list on text-field focus

**This was a real bug.** Home's cards were `if isTyping { suggestions } else { examples }` with `isTyping = isFocused && hasText`. Tapping a suggestion *launched* the workspace instead of filling the prompt. Touching the card resigns the text field on **touch-down**, focus drops, the condition flips, SwiftUI swaps the *examples* list in under the finger — and it's the examples action (launch) that fires on **touch-up**.

Rule: anything that decides which list shows or what a tap does must depend on state that can't change during the tap. `hasText` (is the prompt non-empty) is stable across a tap; focus is not. The hero uses `!isFocused && !hasText` so it stays collapsed after a suggestion fills the prompt.

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

### Feature 2 — Wire up the send flow properly ✅ Done

1. ✅ `handshake://` registered in `Info.plist` (repo root — see §4f)
2. ✅ `onOpenURL` routes `handshake://sign/<uuid>` to `SigningView`, with alerts on the failure paths
3. ✅ On send, `status = .sent` and persist — done in Feature 1 via `SendFlowView.finalize()` → `ContractStore.markSent`

Verified on the simulator with `xcrun simctl openurl`: a valid link opens the signing screen; an unknown UUID shows the "not on this device" alert and dismisses an already-open signing screen first.

### Feature 3 — Face ID signing ✅ Done

**How this actually works:** iOS never exposes biometric data. `LocalAuthentication` returns only pass/fail. So a "face signature" is really:

> Face ID authentication success **+** a cryptographic stamp: `SHA256(signerName + contractID + timestamp + deviceID)`

**Screens / files:**

1. ✅ **Signing screen** (`SigningView`) — read-only contract, a "Signing as" name field, "Sign with Face ID" purple pill
2. ✅ **Auth** (`SignatureService.authenticate`) — `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`. User-cancel is distinguished from failure and shows no error.
3. ✅ **Stamp** (`SignatureService.stamp` + `SignatureBlockView`) — CryptoKit SHA256, then the `[Signature]` placeholder is replaced with a rendered `SignatureBlockView`: name in Snell Roundhand, "Verified with Face ID" badge, ISO timestamp, 12-hex-char fingerprint.
4. ✅ **Confirmation** (`SigningConfirmationView`) — full-screen purple checkmark, then `ContractStore.markSigned`

**Notes worth keeping:**

- **The signer's name is a field, not `recipients.first`.** It's pre-filled from the first recipient but editable — the person holding the device is the one signing and may not be in the list at all.
- **`GeneratedContract` gained `signedBy` and `signatureHash`,** so the record is real rather than cosmetic — the fingerprint on screen is verifiably the first 12 chars of the stored hash.
- **Hash components are joined with `U+001F`,** not concatenated. Without a separator, `("ab","c")` and `("a","bc")` hash identically.
- **The signature block must be rendered at `ImageRenderer.scale = 1`.** The signed body is persisted as RTFD and re-read in the history viewer, and RTFD's importer sizes an attachment by its **pixel** dimensions. Rendering at `UIScreen.main.scale` draws the block 3× oversized after the round-trip, spilling out of the text column. Neither `attachment.bounds` nor a corrected `UIImage` scale survives the import. Cost: the block is slightly soft on a Retina screen.
- Signing an already-signed contract is not possible — the sign bar is hidden when `status == .signed`.

Verified end to end on the simulator with enrolled biometrics: deep link → Face ID prompt → matched face → stamped document → confirmation → Signed in history, with `status`, `signedAt`, `signedBy` and `signatureHash` all persisted.

---

### Feature 4 — Provider-backed signing (decision in progress)

Research on handing the legal weight to an e-sign provider: see the vendor study
(claude.ai/code/artifact/479670c7-8572-41a7-8151-38e1e238e4b6). The finding that
matters: **only DocuSeal lets a signature be applied via the API** (`PUT
/submitters/{id}`, `completed: true`) after our own Face ID step. Every other
provider — DocuSign and Dropbox Sign included — requires the recipient to sign in
*their* UI, so Face ID becomes an unlock in front of a provider screen.

Answers from the product owner (6 Sep 2026):
- **Face ID as the signature vs the unlock:** undecided — prototype both paths.
- **Geography:** global / undecided. eIDAS Advanced/Qualified would narrow to
  DocuSign or Dropbox Sign at enterprise pricing; start US-grade.
- **Backend:** solo designer, no server experience. Whatever is chosen must be
  deployable by pasting keys — the API keys cannot ship in the app (§9).

**What's built (scaffolded, compiles, waiting on accounts):**

- `backend/supabase/functions/handshake/index.ts` — one Supabase Edge Function,
  five routes: an Anthropic proxy (moves the AI key off the phone too) plus
  `docuseal/start`, `docuseal/complete`, `signwell/start`, `signwell/status`.
  Type-checks under `tsc` with a Deno stub. Both providers wired to their TEST
  modes. Setup is in `backend/README.md` — three free signups and two CLI
  commands.
- `SigningProviders.swift` — `SigningBackend` (`.onDevice` / `.docuseal` /
  `.signwell`), `BackendClient`, `SigningProviders.start` (called from the send
  flow; creates the provider document from a PDF), `completeDocuSeal` (Path A,
  after Face ID, with our evidence), `ContractPDF` (US Letter, 1" margins,
  Core Text pagination). `GeneratedContract.providerRef` persists the ids.
- `ProviderSigningWebView.swift` — Path B: SignWell's embedded page in a
  `WKWebView`, finishes on the completion redirect or a posted message.
- `SigningView.sign()` branches on the contract's provider after Face ID. The
  consent line under the button ("By signing you agree to this contract and to
  doing business electronically") is the Path A intent/consent capture and is
  sent to DocuSeal as evidence.
- `Secrets.swift` gained `backendURL` and `signingBackend`. Both default to
  off, so the app behaves exactly as before until they're set.

**Not yet verified end to end** — needs DocuSeal + SignWell + Supabase
accounts, which only the owner can create. `-HandshakeDumpPDF` writes the
provider-bound PDF to Application Support for eyeballing without an account.

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

- [x] **API key out of git** — moved to a gitignored `Secrets.swift` before the repo's first real commit, so it never entered history. Still ships inside the app binary until `backendURL` is set — then `AIService` routes through the edge function and the key stays on the server. Rotate it if it was ever shared.
- [x] `ChatSheetView.swift` deleted (`MessageBubble` moved to `Components.swift` first)
- [x] `ContractEditorView` struct deleted; `RichTextEditorImpl`, the pickers and the markdown parser extracted into `RichTextEditor.swift`, `MediaPickers.swift` and `MarkdownParser.swift`
- [x] Toolbar pills showed a seam / white ring from the iOS 26 glass container — resolved by not painting a custom background inside toolbar items (see §6)
- [x] `handshake://` URL scheme registered — see §4f
- [x] Numbered lists continue from the nearest non-empty paragraph above ("3." → next is "4.") instead of restarting at 1. Logic lives in `ListNumbering` and is unit-tested (8 cases) — the simulator keyboard shifts the toolbar unpredictably, so UI-driving the editor headlessly isn't a reliable test
- [ ] Photo attachments live only in the `NSAttributedString`; they aren't persisted anywhere
- [ ] The iOS 26.3 simulator runtime renders no colour emoji (template icons show as `[?]`). Test on 26.5+
- [ ] A recipient sees the markdown rendering, not the sender's rich-text edits — the RTFD is deliberately excluded from the link payload for size. If that matters, the fix is a real transport (backend or `.fileImporter` with an `.rtfd` attachment), not a bigger link.
- [ ] The stamped signature block is slightly soft on Retina — it has to render 1:1 to survive the RTFD round-trip at the right size (see Feature 3 notes)
- [x] `PurplePillButton` in the nav bar rendered clamped ("S e" wrapped over two lines) — first patched with `lineLimit(1)` + `fixedSize`, then superseded by `ToolbarPillButton` (system glass); see §6
- [x] Malformed AI output (missing `TITLE:` / `---`, or a body under 40 chars) now throws `AIError.malformedContract` with a "try rephrasing" message instead of filing an empty "Agreement"
- [x] ~~Nothing compile-verified~~ — stale since August; everything since has been built and run on the simulator (§0)

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
