# Handshake — Project Handoff

**Last updated:** November 2, 2026
**Status:** Full loop works end to end **across two devices** with no server — send → recipient opens on their own phone → signs with Face ID → signed copy returns to the sender (§0). Provider-backed signing scaffolded, awaiting accounts (§7 Feature 4). Remaining: the §9 list.

---

## 0. August 12, 2026 Update — Persistence + History (Feature 1), compile-verified

Feature 1 from §7 was implemented in a cloud Cowork session without Xcode. It has now been built and partially verified on the simulator — **it compiled clean on the first try, no fixes were needed.**

**New files (project uses synchronized folders — they're picked up automatically):**

- `ContractStore.swift` — `@Observable` singleton, single source of truth. Persists all contracts to JSON at `Application Support/Handshake/contracts.json` (atomic write on every mutation, ISO-8601 dates). Queries: `drafts` / `pending` / `completed`. Mutations: `upsert`, `delete(id:)`, `markSent(id:recipients:)`, `markSigned(id:signedBy:signatureHash:bodyRTFD:)`.
- `HistoryView.swift` — history sheet with sections **Pending Signature · Signed · Drafts**, `StatusBadge` (purple #4C00FF for pending, green signed, red declined, gray draft), swipe-to-delete on drafts, tap draft → reopens `ContractWorkspaceView`, tap sent/signed → `ReadOnlyContractView`. Also holds the `GeneratedContract.displayBody()` extension (RTFD wins over markdown).

**Changed files:**

- `Models.swift` — `GeneratedContract` and `Recipient` are now `Codable`. **`GeneratedContract` uses a hand-written tolerant decoder** (an extension so the memberwise init survives): every field after `content` is `decodeIfPresent` with a default. The store loads with `try? decode … ?? []`, so a strict synthesized decoder would fail the whole file on one missing key, show empty history, and the next save would overwrite it with nothing. Add new fields with a default and a `decodeIfPresent` line. New fields on `GeneratedContract`: `bodyRTFD: Data?` (rich-text edits incl. inline images; takes precedence over `content` for display), `recipients`, `status: ContractStatus` (`draft/sent/signed/declined`), `createdAt`, `sentAt`, `signedAt`. All new fields have defaults, so existing `(id:title:content:)` call sites still compile.
- `ContractWorkspaceView.swift` — new optional `existing: GeneratedContract?` param: when set, loads the saved draft instead of generating (AI panel starts hidden). New `persist()` serializes the editor body to RTFD and upserts to the store; called after initial generation, after every AI update, when leaving edit mode, and `onDisappear`. **Two bug fixes:** AI follow-ups now keep the same contract `id` (previously every update minted a new UUID → would have duplicated drafts), and `persist()` re-reads status metadata from the store so closing the workspace can't regress a just-sent contract back to draft.
- `SendFlowView.swift` — tracks compose results; only when SMS/Mail actually reports sent does `finalize()` call `ContractStore.markSent` (recipients + timestamp), then shows the Sent confirmation. The `UIActivityViewController` fallback does *not* mark sent.
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
- **The Send pill in the workspace toolbar rendered as "S / e" on two lines.** The iOS 26 glass container squeezes the item and wraps the label. `PrimaryPillButton` now has `lineLimit(1)` + `fixedSize(horizontal: true)`, which stops the wrap without changing the geometry §6 warns about.
- **The share-sheet fallback was a dead end.** It passed `[subject, body]` as two items, which iOS described as "2 Images", and on dismissal dropped the user back on the send form with no feedback and no status change. It now shares one combined string and, when a share *completes*, asks "Did you send it?" — marking sent only on an explicit yes, since the share sheet can't distinguish Mail from Copy. The §0 rule that the fallback never marks sent silently still holds.
- **A signing link arriving while the workspace was open was silently dropped.** The workspace is a `fullScreenCover` from `HomeView`; SwiftUI won't present `RootView`'s cover on top of it, so tapping "Open in Handshake" did nothing. `DeepLinkRouter.dismissAll()` now tells `HomeView` to close its cover and history sheet before `RootView` presents, ~400 ms later.
- **The workspace didn't reflect a contract being sent from inside it.** It now reads status live from the store: a Pending/Signed badge appears beside the title, and Send is replaced by the Signed badge once signed (editing a signed document would invalidate the stamp).

The full loop — draft → sent → signed, with signer, timestamp and hash persisted — now completes on the simulator with no device and no Mail account.

**Design review pass (November 3, 2026):** every screen was reviewed against the HIG using the `mobile-ios-design` skill (`~/.claude/skills/mobile-ios-design/`). Critical and high findings are fixed; the rest are in §9.

- **Dark Mode was broken, not just unsupported** (fixed Nov 7). The hardcoded #FAFAFA / #F5F5F4 backgrounds stayed light while `Color(.label)` text flipped to white. The light lock is gone: every hand-picked colour now lives in `Theme.swift` with a dark value, and everything else is a system colour.
- **Dynamic Type did nothing.** All 69 fonts were fixed point sizes. They're text styles now (17 → `.body`, 15 → `.subheadline`, 13 → `.footnote`, 12 → `.caption`, 28 → `.title`, 30 → `.title`, 20 → `.title3`, 16 → `.callout`) with the Figma weights kept; icon squares, the formatting toolbar and pill heights use `@ScaledMetric`. The document uses `UIFont.preferredFont(forTextStyle: .body)` with `adjustsFontForContentSizeCategory`. Decorative sizes (illustration symbols, the 84 pt checkmark) and the rendered field/stamp PNGs stay fixed on purpose. Verified at the largest accessibility size.
- **VoiceOver:** every icon-only button has a label (`GlassIconButton` requires one; `FormattingToolbar` buttons carry theirs); the confirmation's timestamp + fingerprint read as one element.
- **Safe areas:** the 34 pt "home indicator" paddings are gone. The signing bar is a `safeAreaInset` whose background bleeds into the safe area; the workspace chat bar pads 8 inside the safe area like Home (34 had doubled it, so the pill sat higher than on Home).
- **Signing button:** `.disabled` instead of opacity + `allowsHitTesting`, "Enter your name to sign." under the field when empty, and the label names the device's biometry (`SignatureService.biometryName`).
- **AI panel never reached large** — see the §6 gotcha on `GeometryReader` inside a `fullScreenCover`. It rests at a `PanelDetent` now and behaves like the Maps sheet: at medium the message list is scroll-disabled so a drag anywhere on the panel resizes it; at large the list scrolls and a downward drag from its top (tracked with `onScrollGeometryChange`) collapses it; the handle strip always works. Flicks decide by velocity. The chat bar reads "Edit with HandShake" once a document exists.
- **Long titles ran under Send/Close** on reopen — see the §6 gotcha on principal toolbar items.

**First-time-user walkthrough (November 1, 2026):** wiped the store and walked home → prompt → generate → edit → signature + date boxes → send → sign on a second phone, judging each screen as someone who'd never seen the app. Fixed on the spot, all verified on the simulator:

- **The toolbar's signature box could never be signed.** It inserted a decorative "Signature   Date" rule, but the stamp searches for the literal `[Signature]`. Mismatch → the stamp fell to the *end of the document*. Now inserts `Signature: [Signature]` / `Date: [Date]` — the same tokens the AI emits and the signer looks for.
- **There was no date box.** New calendar toolbar button inserts `Date: [Date]`; signing fills the `[Date]` after the chosen signature with the signing date.
- **Inserts tore words in half.** They went in at the raw cursor; mid-sentence that produced "[TENANT'S CURRENT" / "ADDRESS]". Both inserts now land at the end of the current paragraph (`insertFieldBlock`).
- **Generated contracts had no signature block** (the prompt never asked) **and ended with the model's own legal-advice paragraph** baked into the body. The prompt now requires a `**SIGNATURES**` block with `[Signature]`/`[Date]` per party and forbids commentary. Verified: 2 + 2 tokens on first generation, no trailing advice.
- **The stamp always replaced the first `[Signature]`** — so a tenant's signature landed in the landlord's slot once every contract had a per-party block. `SignatureSlots` finds each token and its role from the nearest `ROLE:` line above; with >1 slot the signing screen shows a segmented "Sign as" picker, defaulting to the last party (the sender lists themselves first). Unit-tested (7 cases, incl. a user-placed box with no role line → "Party 1", and roles not bleeding across slots). Verified: tenant's stamp under TENANT, landlord's tokens untouched.
- **"Created!" wasn't persisted** — same append-after-`persist()` ordering as the follow-up bug fixed in October, in the initial-generation path.
- **Entering edit mode left the AI panel covering half the document** with the formatting toolbar squeezed under it. Editing now collapses the panel; the chat bar brings it back on send.

**Still open from the walkthrough — design calls, not changed:**

- ~~The chat bar's + and mic icons do nothing~~ — fixed: mic is real dictation (`SpeechInput`, SFSpeechRecognizer); "+" is a Photo / File menu in the workspace and hidden on Home where there's nothing to attach to.
- ~~`needsClarification` / `getClarification` defined but never called~~ — removed. The heuristic rarely fired anyway (any prompt ≥10 words skipped it), and the AI suggestions on Home cover the vague-prompt case better.
- ~~Generation shows a blank page for ~20 s~~ — fixed: `GeneratingSkeleton`, a pulsing document-shaped placeholder.
- The signing screen's "Signing as" name is pre-filled from the first recipient, but with a **multi-party contract the sender never fills in party names** (`[FULL NAME]` stays), so the recipient can't tell which role is theirs from the document alone — the picker labels (Landlord / Tenant) carry that.

**Signature + date fields (November 2, 2026):** the toolbar "box" was two lines of text, and a box the sender placed never reached the recipient. Both fixed — see Feature 3 notes and the §6 attachment-name gotcha. One cosmetic nit left: inserting a second field right after the first leaves an extra blank line between them.

**Follow-up fixes (November 1, 2026):** the four walkthrough design calls, resolved:

- **Example cards on Home couldn't launch** — a regression from the focus/tap fix. `hasText` reads `prompt`, and the tap handler checked it *after* assigning `prompt = t.prompt`, so it was always true and the launch branch never fired. Tapping a template just filled the bar. Decide before assigning. (Caught because the walkthrough re-ran from a wiped store.)
- **Mic is real dictation** (`SpeechInput`: SFSpeechRecognizer + AVAudioEngine, partials streamed into the field, tap again to stop). Permission strings in `Info.plist`. Recognition failures surface as an alert rather than the mic silently flipping back. *Not verifiable on the simulator* — it has no usable input device; the engine starts, the session gets no audio, and the "Couldn't hear anything" alert is what you see. Test on a device.
- **"+" is a Photo / File menu** in the workspace (same pickers as the toolbar); hidden on Home where there's nothing to attach to.
- **`GeneratingSkeleton`** replaces the ~20 s blank page during first generation.
- **Clarification flow removed.** `needsClarification` / `getClarification` were never called, and the heuristic skipped any prompt ≥10 words anyway. Home's AI suggestions handle the vague-prompt case.

**Conversation persistence (October 23, 2026):** the AI chat is saved on the contract (`GeneratedContract.messages`) and restored on reopen, with the panel already open at medium when there's history. Three things fell out of making that work, all verified on the simulator:

- **Follow-ups sent only the transcript.** The model never saw the document, so "add a clause" came back as a snippet — which the new `malformedContract` guard correctly rejected (and which, before that guard, used to *replace the whole body* with the snippet). `sendToAI` now sends the current document text plus the transcript and asks for the complete revised contract. The document text (`attributedBody.string`), not `contract.content`, so the user's manual edits are what gets revised.
- **`max_tokens` was 2048** — about 7.5K characters, the size of the contracts being revised. Raised to 8192 for generation.
- **The "Updated!" reply was appended after `persist()`**, so it never reached disk. Order fixed.
- The prompt's `**Section Header:**` example was being echoed literally as "Section Header: 1. PROJECT SCOPE". Reworded.

**Two-device pass (September 12, 2026):** sender on an iPhone 17 Pro, recipient on a **separate, empty** iPhone 17 (its store wiped first). Before the change, the recipient hit the "not on this device" alert — the link was just a UUID. After:

1. Sender's link (built by `SendFlowView` from the store, recipients included) opens on the empty recipient → contract stored locally, `SigningView` shows it with Pending badge, "Signing as" pre-filled from the payload.
2. Recipient signs with Face ID (real `LAContext`, simulated matching face) → `signed`, `signedBy`, `signedAt`, `signatureHash`, stamped RTFD all recorded on the recipient.
3. Recipient's History lists it under Signed.
4. The "Send signed copy back" link opens on the sender → sender's record moves to `signed` with the **same hash** the recipient produced; still exactly one entry; read-only viewer presented.

One detour worth knowing: restarting SpringBoard on a simulator (`launchctl kickstart -k system/com.apple.SpringBoard`) **wipes its Face ID enrollment**. The first sign attempt failed with "Biometry is not enrolled" — which the app surfaced as a clean alert, so that error path is verified too. Re-enroll with `notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` + `-p`.

**Verification tooling notes (environment, not app bugs):**

- **`xcrun simctl openurl` truncates URLs at 2,047 characters.** Every real signing link is longer (5–10K), so opening one that way shows "This link is incomplete". It is the tool, not the app: the same link tapped in Safari arrives whole. To test links, put them in a page (`python3 -m http.server` on the Mac; the simulator reaches `localhost`) and tap them in Safari.

- The Claude simulator MCP *build* server can't read `Handshake/Assets.xcassets` (`actool` permission error, though the same command works from a normal shell). Build with `xcodebuild` directly. Its `control`/`attach` action works once Xcode is properly selected.
- The `#if DEBUG` launch-argument hooks (`-HandshakeOpenHistory`, `-HandshakeDumpPDF`, `-HandshakeOpenURL`, `-HandshakeAutoSign`) were **removed on November 6, 2026** as release prep. Drive the same flows without them:
  ```
  xcrun simctl openurl <udid> 'handshake://sign/<uuid>'                    # open a signing link (no prompt while the app is frontmost)
  xcrun simctl spawn <udid> notifyutil -p com.apple.BiometricKit_Sim.pearl.match   # answer Face ID with a match
  ```
  History is the menu button on Home. Take a second screenshot ~0.5 s after a gesture: one taken immediately can catch a spring animation mid-flight and look like the gesture did nothing.

---

**Recipient flow pass (November 8, 2026):** sender iPhone 17 Pro → fresh-install recipient iPhone 17 → back. Fixed:

- **The sender's "Signed" copy showed the signer's box still empty.** Only the status and hash came back; the stamp lived only on the recipient's phone. The signed-copy link now also carries which slot was signed (`signedSlot`) and the date entered (`signedDate`), and `RootView` re-draws the stamp into the sender's own document (their RTFD edits kept). Opening the same copy twice doesn't stamp twice (hash check).
- **A recipient who closed the signing screen couldn't sign later** — the contract sat under "Pending Signature" and opened read-only. Copies that arrive by link are now `isIncoming`; History lists unsigned ones under **Waiting for You** (badge "To Sign") and opens the signing screen.
- **A re-sent, edited contract didn't reach the recipient** — the old local copy always won. An unsigned incoming copy is now replaced by the newer link; the sender's own record is never touched.
- **"Not now" after signing was the last chance to send the copy back.** The read-only viewer of an incoming signed contract has a share button that sends it.
- **Share sheet "Copy" counted as sent** ("Copy sent ✓"). Copy now reads "Link copied. Paste it to the sender".
- **The signing date was dropped from the copy sent back** — read after stamping had already filled the date box.
- The confirmation showed a raw UTC ISO timestamp; now a local date and time.
- **Recipients couldn't tell who sent it.** The link carries the sender's name when they're signed in with Apple (`from`); shown on the signing screen and in History ("From …"). The invite text names them too, and no longer claims the link is "unique to you" (every recipient gets the same link).
- Link errors distinguish a cut-off link ("This link is incomplete…") from a link with no payload.

**Parties and the recipient redesign (November 8, 2026, evening)** — modelled on DocuSign / Dropbox Sign. See `Parties.swift` for the model.

- **Signatures are records, not pixels.** `GeneratedContract.signatures: [PartySignature]` (slot, role, name, time, hash, date, method). The document stays unsigned (`baseBody()`); `displayBody()` draws each stamp into its box on the way to the screen, fills that party's date field (only up to the next party's block) and writes the signer's name over the placeholder on their party line ("TENANT: [FULL NAME]" → "TENANT: Dana Whitfield"). Copies **merge** by slot — a second signer no longer overwrites the first. Old records (stamp baked into the RTFD, no records) show exactly as before. The workspace edits `baseBody()`; if the wording changes, the signatures on the record are dropped (`persist()`).
- **Parties first (send screen).** The page lists **one row per signature box** under "Who signs" — the contract names the parties, the sender says who each one is. A row shows the party ("Client"), a monogram, and who: "You · name", "name · contact", or "Choose who signs". Tapping opens a sheet (`PartySheet`): **Me** (sign with Face ID before it's sent), or **someone else** — full name plus one **Email or phone** field (an "@" makes it an email; the other is cleared so an old number can't take over delivery), **Choose from Contacts** (`ContactPicking`: the system picker presented from UIKit, no Contacts permission), and **People you've sent to** (past recipients, most recent first, filtered as you type; people already on this contract left out). **Remove Signer** clears a party. One box, one signer: choosing Me for a party takes it from whoever had it. A document with no boxes lists "Signer 1, 2…" instead (no Me option).
- **Adding a signer = adding a box.** There can't be more signers than boxes. **Add Signer** asks what they sign as ("Witness", "Guarantor"), then appends `ROLE: [FULL NAME]` / `[Signature]` / `[Date]` to the end of the contract (`addSignatureBox`, written to the store with `setBody`) and assigns the person to the new party. **Remove Signer** on a box added this way takes the box back out too (`removeSignatureBox`; parties after it move up one) — boxes the contract came with stay. In a document without boxes it just adds a signer.
- **The sender countersigns** by being one of the parties (the Me choice); the button reads **Sign & Send** then (Face ID first). The signature is saved only once something is actually sent.
- **Below the signers:** the problems list (after a Send tap), then the **blanks alert** — compact and must-fix: "N blanks to fill in", the first two by name ("Effective Date, State/Country and 19 more") and a small **Fill In** on the right (green "All blanks filled in · Review" once done) — then a one-line **"Signed copies come back to … Change"** (an alert with a text field).
- **How "Signs as" is decided (no AI at send time).** Party names come from the contract text: each signature box's label line ("CLIENT:", "甲方：") via `SignatureSlots.find` — plain rules, same answer on every phone. Who is which party:
  1. **Sender** — `GeneratedContract.senderRole`: the sender's last choice (`""` = not signing), else the AI's guess from the prompt (the draft starts `TITLE:` / `SENDER: FREELANCER` / `---`; `NONE` when unclear; AI edits update it only before the first send), else the one box left over.
  2. **Recipients** — matched by **party name** (`Recipient.partyRole`, saved at send) first, so a revision that reorders or adds boxes doesn't swap roles; then by box number (older records); then the next free party.
  3. The sender can override any of it from the party rows.
  Missing details (recipient contact, the sender's name, a box no one is signing) are listed only once Send is tapped, and the rows' own hints turn orange — the button isn't greyed out — and each line disappears as it's fixed.
- **One link per recipient** (`me` in the payload = their box), one compose sheet each — Messages if they have a phone, else Mail, else the share sheet. The recipient sees "You're signing as Tenant", no picker. Older links without `me` still get a picker, limited to unsigned boxes.
- **"1 of 2 signed".** `partyCount` is set at send; the sender's copy turns Signed only when every box has a signature. Read-only viewer lists the signers (✓ time / Waiting). A completed copy can be sent round from there.
- **Recipient's Signed screen** draws the owner's check-circle doodle (`CheckDoodle.swift`, same pen animation as the sender's paper plane) instead of the blue system check.
- **Recipient screen:** one-row bar (Figma 2011:54312) — a glass **search** circle on the left (same find bar as the editor: highlights, ↑/↓, ✕) and the ink **Sign as Tenant** pill on the right, hugging its label. The bar has no backdrop — the buttons float over the contract. One contextual glass capsule above them while scrolling: **Back to top** when scrolling up (once more than a screen down), otherwise **Jump to signature**, which appears only while scrolling (`onScrollPhaseChange`) and only while their box is off screen (`onScrollGeometryChange` → `updateBoxDirection`; the arrow points up or down to it), and fades 1.5 s after the scroll settles. After either is tapped it stays hidden until the signer drags again (`jumpDismissed`, cleared on `.interacting` — the jump's own animated scroll doesn't count). It floats in an overlay with a fixed offset, so showing or hiding it never changes the bar's inset (that cut the jump's scroll short). Back to top uses SwiftUI's `ScrollPosition` (`docScroll.scrollTo(edge: .top)`); name / date / consent / Face ID live in a sheet. The bar fades out under any sheet (iOS 26 glass sheets let the purple pill glow through). The status badge sits under the title (above "From …") so the title gets the full width. ⋯ menu: **Ask for Changes** (free text — the explanation above a grey text box; a native Form was tried and the owner preferred this) and **Decline to Sign** (optional reason) — both go back as `handshake://reply/<id>?d=…`. Sender side: "Changes Asked" / "Declined" badges, a banner, and **Revise Contract** (back to draft, signatures cleared, the request pre-filled in the chat bar for the AI).
- **Replies come back addressed.** "Signed copies come back to" (email or phone, remembered; the line under the send form) rides in the link as `reply`; the recipient's Send-back / decline / changes open Mail or Messages already addressed (`ReplyComposeSheet`), share sheet as fallback. Apple private-relay addresses are skipped (they bounce non-registered senders).
- **Blanks.** The AI is told to put "[BRACKETS]" around anything the user must fill in; the app finds them with plain rules (`SignatureSlots.blanks`: any "[…]" up to 48 characters, not the field tokens, not the name on a party line). The send screen's blanks alert opens **Fill In Blanks** — one field per blank with the sentence it sits in (`SignatureSlots.context`). Name blanks fill themselves from the send screen: "[FREELANCER FULL NAME]" → whoever signs as Freelancer (`SignatureSlots.party(forNameBlank:)`; skips company/business names). Values are written into the document (`GeneratedContract.setBody`, RTFD + markdown) at send — before the links and the sender's signature — and typed values also whenever the page is left (back button or edge swipe — `onDisappear`). The workspace reloads from the store when the send page goes (`onClose` → `reloadFromStore`), so its next `persist()` can't write the old text back. Anything still unfilled is confirmed before sending ("Send Anyway" / "Fill In"). **After the form:** closing Fill In Blanks with anything typed writes it in straight away and takes the sender back to the document (`onBlanksFilled`): the workspace reloads the stored copy, highlights every filled spot with the search highlight (`DocumentSearch.decorate` — draw-only, never saved; positions from `SignatureSlots.fillTracking`), scrolls to the first, and shows a toast — "Contract updated · N blanks filled in, highlighted below". The toast goes after 5 s; the highlights stay until the sender edits, searches, asks the AI, or sends.
- **AI edits keep the formatting.** The revision request sends the document as markdown (`handshakeMarkdown()`: **bold** runs, `[Signature]` / `[Date]` tokens), not plain text, and tells the AI to keep every bold run, the numbering and the field tokens as they are. Plain text had dropped the bold ("WALKER:" came back un-bolded) and turned boxes into U+FFFC. Only bold survives the round trip — italic, underline, headings, alignment and photos aren't in the markdown, so an AI edit still resets those.
- **Suggested next steps (chat).** Under the latest assistant reply, chips that wrap onto as many lines as they need (`suggestionRow`, laid out by `WrapLayout` in Components.swift): **Fill in N blanks** (the app's own — opens the same Fill In Blanks form on the contract; on close the values go straight into the document, then the same highlights and toast) and the AI's own ideas for that contract ("Add a vet emergency clause"). Those come from a `NEXT:` line the AI writes in its header with every draft and revision (`GeneratedContract.nextSteps` → `ChatMessage.suggestions`), so they cost no extra call; tapping one sends it as a request. The AI is told not to suggest filling the bracketed fields. Who signs what is kept with the draft when the send page is left (`saveDraftSigners`), so going back to Send starts from it.
- Stamp shows local time with zone (was ISO UTC). App icon: the owner's handshake drawing (`Documents/All Doodles/Special Characters/handshake.svg`, view box cropped to the strokes) in ink #1F1E1C on #FAFAF9, plus dark (#EDECE9 strokes) and tinted (white) variants on transparent. The same drawing is the `handshake-glyph` vector template asset, shown at the left of the chat bar at rest; "+" replaces it once the bar is tapped.
- Not done (needs a domain/backend, owner decision): web / universal links and short links; per-recipient tracking beyond what links carry; signing order.

## 1. What Handshake Is

A native iOS app that turns a plain-English prompt into a legally formatted contract, lets you edit it like Apple Notes, then send it to recipients who sign with Face ID.

**Core loop:** Prompt → AI generates contract → Edit inline → Send to recipients → They sign with Face ID → Archived in history.

**Product bet:** The AI chat panel is the hero. It's always accessible, never hidden behind a modal — you can talk to it while looking at the contract.

---

## 2. Stack & Setup

| | |
|---|---|
| **Platform** | Native iOS 26, SwiftUI |
| **AI** | Anthropic Messages API, `claude-haiku-5-5` (adaptive thinking; effort `low` for suggestions, `medium` for contracts) |
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
| `Components.swift` | Shared UI: ChatBar, toolbars, `GlassIconButton` / `ToolbarPillButton` (system glass) / `PrimaryPillButton` (custom, full-width only), illustration, `MessageBubble` |
| `RichTextEditor.swift` | `RichTextEditorImpl` — the `UITextView` ↔ SwiftUI bridge |
| `MarkdownParser.swift` | `NSMutableAttributedString.fromHandshakeMarkdown` |
| `ListNumbering.swift` | Pure Foundation: what number the next list item gets. Testable outside the app |
| `SpeechInput.swift` | Dictation for the chat bar — SFSpeechRecognizer + AVAudioEngine, partial results streamed into the field |
| `SignatureFields.swift` | The field model: `.signature` / `.date` as attachments in the document, `[Signature]` / `[Date]` in markdown; lossless both ways. Detection, `handshakeMarkdown()` (document → markdown), `renderFieldTokens` |
| `SignatureFieldViews.swift` | The dashed box images, rendered at 3× |
| `SignatureSlots.swift` | Pure Foundation: every `[Signature]` in a document and whose it is (from the `ROLE:` line above), its date field and party line; `blanks(in:)` for unfilled placeholders |
| `Parties.swift` | `baseBody()` / `displayBody()`, drawing `PartySignature` records into their boxes, merging copies, "N of M signed" |
| `ComposeBridges.swift` | Messages / Mail compose bridges + `ReplyComposeSheet` (a reply already addressed to the sender) |
| `MediaPickers.swift` | `PhotoPickerView`, `DocumentPickerView` |
| `SendFlowView.swift` | Recipients and the party each signs, the sender's own signature, blanks warning, one link per recipient |
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
- **AI suggestions** (`AIService.suggestPrompts`, Haiku 5.5 at effort `low`, `max_tokens` 1024 so thinking has room): fired ~450 ms after the last keystroke on ≥3 characters, cancelled by the next keystroke, cached per lowercased query, and skipped when the text is exactly a suggestion that was just tapped. The model returns `EMOJI | TITLE | PROMPT` lines; anything unparseable is dropped. On any failure the local ranking simply stays up — there's no error state, by design. The suggestions state isn't drawn in Figma (frame 18 shows typed text with the example cards); the 3-card layout reuses `TemplateCard`.

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
| Signature | Places a **signature field** — a dashed box the recipient signs (Face ID → stamp). Lands on its own line after the current paragraph (**first**, per design) |
| Date | Places a **date field** — a dashed box the recipient fills by picking a date (defaults to the day they sign) |
| Text style | Bold, Italic, Underline |
| Headings | H1 (26pt bold), H2 (20pt bold) |
| Lists | Bullet (•), Numbered (1. 2. 3.) |
| Alignment | Left, Center, Right |
| Insert | Photo (inline `NSTextAttachment`), File attachment |

All formatting operates directly on `UITextView.textStorage` so the cursor never jumps.

### 4d. Send flow (`SendFlowView`)

- Its own step: pushed onto the workspace's NavigationStack (`navigationDestination`), not a sheet. System back button (hidden only while signing) and edge swipe return to the document; **Sign & Send** / **Send** sits top right. Pushing makes the workspace's `.task` run again on return — `generateInitial()` is guarded by `didStartInitial` so it doesn't reload the stale draft or regenerate.
- **Sent confirmation** (`sentPage`): after `markSent` the form is replaced, in place, by the Sent page. Top: the owner's paper-plane doodle drawn in like a pen (`PaperPlaneDoodle.swift`: outline, fold, tail, then a small toss; static under Reduce Motion), "Sent for Signing", the title. Then one **timeline** (`sentSteps`) instead of cards — ✓ You signed as … (method · time), ✓ Sent to each person (role · Messages / Mail / Link shared), ○ they sign (Waiting), ○ Signed copy comes back (to the reply address) — steps fade in one by one after the plane. A person whose compose sheet was cancelled gets an orange **Not sent to …** step with **Send** (`deliver([r])`); "Not yet" on the share-sheet question puts that round's shares back to not sent. Bottom: **Done** (closes the contract — `onDone` reloads from the store first, then dismisses the workspace) and **View Contract** (pops to the document, now Pending). No nav bar or back button on this page.
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

### The phone's AI panel slides by offset; it is never inserted/removed
As an `if showAIPanel { aiPanel.transition(.move…) }` the insertion never animated when opened from a chat-bar tap (it popped in at full height; closing was fine). It's now always mounted and offset below the screen when closed (`allowsHitTesting`/`accessibilityHidden` follow `showAIPanel`). Tapping the bar opens the bar full width (`ChatBar(expandsOnFocus:)`) while the panel rises out of it; swiping the panel away also resigns the bar's focus so it returns to the resting pill + search button.

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
- `PrimaryPillButton` (custom gradient) is now only for full-width actions **outside** toolbars — the signing screen and confirmation — where there's no system container to fight.

### UIKit renames every text attachment to "Attachment.png"

A field's identity can't live in its file name. `FileWrapper.preferredFilename` survives an RTFD round-trip under **AppKit** — which is why a macOS unit test passed — but UIKit regenerates the wrapper from the image whenever it writes, and even a freshly created attachment reports `Attachment.png` on iOS. `SignatureField.kind(of:)` therefore reads the **box size** (300×64 signature, 170×44 date, or any 1×/2×/3× multiple of it, since the boxes now render at 3×), with the name only as a secondary check. Custom attributes don't survive RTFD either. A related trap in testing: `print()` never reaches `log show` on the simulator — use `os.Logger` at `.notice` or above (`.debug` isn't persisted).

### RTFD drops attachment bounds, so point sizes are saved beside it

iOS's RTFD importer sizes every attachment by its **pixel** dimensions and throws away `bounds`. That's why the stamp and boxes used to render at 1× (right size, soft on Retina). Now everything Handshake draws into a document renders at `SignatureField.renderScale` (3×), and `persist()` / `markSigned` store each attachment's point size, in document order, in `GeneratedContract.attachmentSizes`; `displayBody()` puts them back with `applyAttachmentSizes`. If the count doesn't match (an older record) nothing is touched, so 1× records still display as they always did. **Any new code that writes `bodyRTFD` must write `attachmentSizes` with it.**

**RTFD keeps an attachment only if it has data.** An `NSTextAttachment` with just `image` set is silently dropped when the document is written as RTFD. Give it bytes — `NSTextAttachment(data:ofType:)` or a `fileWrapper`. When `image` is also set, iOS writes the image as PNG and ignores the bytes you gave it, so for photos leave `image` nil and let TextKit draw from the JPEG data. Small drawn images (fields, the stamp) set both; PNG is fine there.

### Measure a drag on a moving view in global coordinates

The AI panel moves with the finger while it's dragged, so a `DragGesture` in the panel's own (default, local) space sees the finger barely move: translation near zero and a velocity that can come out **reversed** — a flick down snapped the panel to large. `DragGesture(coordinateSpace: .global)` measures against the screen.

### Don't branch a tappable list on text-field focus

**This was a real bug.** Home's cards were `if isTyping { suggestions } else { examples }` with `isTyping = isFocused && hasText`. Tapping a suggestion *launched* the workspace instead of filling the prompt. Touching the card resigns the text field on **touch-down**, focus drops, the condition flips, SwiftUI swaps the *examples* list in under the finger — and it's the examples action (launch) that fires on **touch-up**.

Rule: anything that decides which list shows or what a tap does must depend on state that can't change during the tap. `hasText` (is the prompt non-empty) is stable across a tap; focus is not. The hero uses `!isFocused && !hasText` so it stays collapsed after a suggestion fills the prompt.

### A `GeometryReader` inside a `fullScreenCover` measures 0 on its first layout

**This was a real bug for months.** The workspace measures its content area with a `GeometryReader` and read `geo.size.height` once in `onAppear`. Inside a `fullScreenCover` that first layout reports **0**, so `contentH` stayed 0 and the panel's detents sat at their `max(…)` floors — medium 200 pt, large 300 pt. "Large" was barely taller than medium, which is why the panel seemed not to expand. Take the first non-zero value from `onChange(of: geo.size.height)` as well as `onAppear`. The §6 rule above still holds: the height comes from the GeometryReader, never `UIScreen`.

### Don't put a long title in a `ToolbarItem(placement: .principal)`

On iOS 26 a principal `Text` with `lineLimit(1)` is laid out at its full width when the *first* layout already has a long title (a reopened draft, the signing screen) and runs under the trailing button; it only truncates when the title starts short and changes later. Use `.navigationTitle` with `.inline` — the system truncates, and it's the same 17 pt semibold.

### `ShareLink` doesn't work as a toolbar label

`UINavigationBar` clamps its intrinsic size to a small square. Use a plain `Button` + a state flag + `UIActivityViewController` (see `ActivityView` in `Components.swift`).

### Design tokens

```
Ink               #1F1E1C / dark #EDECE9 (`ink`, `onInk` #FFFFFF / #1F1E1C) — warm, Notion-like.
Primary action    `action` = ink for now (Send pills, send circle, chat placeholder, filled pill /
                  circle buttons, iPad Edit toggle, text cursors). Swap `action` for the accent later.
User chat bubble  #1F1E1C, white text / dark: #3A3936, #EDECE9 text
Secondary text    #787774 / dark #9B9A97
Page / card       #FAFAF9 (stone/50) / #F5F5F4 (stone/100); system colours in dark
Accent            `accent` = Color.accentColor — the AccentColor asset is EMPTY, so it's iOS's
                  default blue. Links, "Choose who signs", Add Signer, Change, the
                  signature-field boxes (wash #F0F7FF), the "Verified with Face ID" badge.
                  Set AccentColor in Assets to rebrand all of them. No purple left anywhere.
Profile avatar    systemGray2 → systemGray, like Contacts' monogram
Body text         SF Pro Regular 17 / 22, tracking -0.43  → `.body` (scales with Dynamic Type)
Title             SF Pro Bold 28 / 34, tracking 0.38      → `.title.weight(.bold)`
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
- **The signature block renders at 3× and its point size is saved beside the RTFD** (`attachmentSizes`; see the §6 gotcha). It used to render at 1× because RTFD's importer sizes attachments by pixels and drops `bounds` — rendering at screen scale drew it 3× oversized after the round-trip. Verified Nov 6: sharp, right size, after a relaunch.
- Signing an already-signed contract is not possible — the sign bar is hidden when `status == .signed`.
- **Fields, the e-sign way (Nov 2):** the sender *places* fields, the recipient *fills* them — the DocuSign / Dropbox Sign model. A field is an `NSTextAttachment` drawing a dashed box in the document and a `[Signature]` / `[Date]` token in markdown (`SignatureField`). The AI emits tokens; the toolbar inserts boxes; `persist()` writes the document back to `content` as markdown (`handshakeMarkdown()`, bold preserved), so a box the sender places **reaches the recipient** — before this, `content` was frozen at the AI's first draft and sender edits never crossed.
- **Which slot gets the stamp:** `SignatureSlots.find` lists the signature fields with their party (nearest `ROLE:` line above); the picker's choice is passed as `stampSignature(…, slot:)`. Default is the last party. The **date field** after the chosen slot is filled with the date the signer picked in the `DatePicker` (defaults to today); other date fields are left for other signers.
- Verified across two simulators: sender places a signature + date box mid-document, sends; recipient sees all three fields, signs as Developer with today's date → stamp under DEVELOPER, date filled, the Client's and the sender-placed fields untouched; signed copy returns to the sender with a matching hash.

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
accounts, which only the owner can create.

**Setup in progress (Nov 9):** Supabase CLI installed (`brew install supabase/tap/supabase`). Parked until the owner's UI fixes are done. Owner: DocuSeal sign-up (wei@studiolofi.com, test key `…+test`); a new Supabase project "handshake" in their existing account (separate from their lofi project); `supabase login`; `supabase secrets set ANTHROPIC_API_KEY=… DOCUSEAL_API_KEY=…` from `backend/`. Then: link, `supabase functions deploy handshake --no-verify-jwt`, `backendURL` + `signingBackend = .docuseal` in Secrets.swift, first end-to-end test. Setting `backendURL` sends all AI calls through the server, so the Anthropic key must be there first. SignWell isn't needed for this (keys are read per route). (`ContractPDF.render` builds the
provider-bound PDF; the debug hook that dumped it to disk was removed Nov 6.)

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
- [x] **Dark Mode** (Nov 7). `Theme.swift` holds the app's own colours with light (Figma) and dark (system palette) values: `pageBackground`, `cardFill`, `raisedSurface`, `primaryInk`, `secondaryInk`, `userBubble`, status colours, and two purples — `brandFill` (#4C00FF behind white text, both modes) and `brand` (#4C00FF light / #9D80FF dark, purple *as* text or icon; #4C00FF on black is ~2.3:1). The Home illustration is inverted in dark. Things inside the document are images and keep one light "paper" look in both modes: the signed stamp and the Signature/Date boxes render with `.colorScheme(.light)`, and the boxes now have an opaque wash. On load (`displayBody()`), plain black/white text goes back to `.label` (`adaptTextColorsToAppearance`, RTFD stores the resolved colour) and field boxes are redrawn (`redrawSignatureFieldBoxes`) so drafts saved earlier also read in dark.
- [x] **iPad / wide screens** (Nov 7). Content is capped at a 640 pt reading column and centred (`readableColumn()` in `Theme.swift`): Home cards and chat bar, the workspace document, AI panel and chat bar, the signing screen and its sign bar, Send for Signing, and the read-only viewer. Backgrounds still fill the screen. Copy that said "this iPhone" now names the device.
- [x] **iPad side panel for the AI chat** (Nov 8). At regular width the workspace has no bottom sheet: the conversation is a trailing side panel (SwiftUI `.inspector`, 320–480 pt) with the chat bar at its foot, opened and closed by an **Edit** toggle in the toolbar. New contracts open with it showing (so drafting progress is visible); reopened drafts open on the document. Typing in the document puts the formatting toolbar at the foot of the document column. Split View / Slide Over at compact width falls back to the phone sheet. The thinking indicator no longer shows a sparkle icon (owner's call), and the Edit toggle has none either.
- [x] **Find in contract (phone)** (Nov 8). A magnifier circle sits left of "Edit with HandShake"; tapping it turns the bottom bar into a search bar (Figma iOS 27 kit 12740:24039: capsule + ✕ circle). Matches words and the Signature / Date boxes ("sign", "date"). Highlights are TextKit 2 rendering attributes (`DocumentSearch.swift`), never written to the text, so they can't reach the saved RTFD. Count + ↑/↓ step through matches; Return goes to the next. Typing in the document ends the search. A soft fade now sits under the bottom bar whenever the panel is down, so document text no longer runs through the translucent pill. iPad has no search yet (its bottom bar lives in the side panel).
- [x] Haptics: success on signing and on a confirmed send, a light tap when a field lands (`Haptics` in `Components.swift`; imperative because both success moments are followed by a dismiss)
- [x] Two fields inserted back to back drifted apart a blank line at a time — `insertFieldBox` now stacks them, keeps one blank line from surrounding text, and puts the caret after the box (unit-tested, 6 cases)
- [x] `#if DEBUG` launch hooks and stray `print`s removed
- [x] Home's profile button opens **Profile** (`ProfileView.swift`, Nov 6): Sign in with Apple account (`AccountStore` in `Account.swift`, on-device; Log Out forgets it, contracts stay), plan and billing through StoreKit (Apple's manage-subscriptions sheet, `AppStore.sync()` restore), and a Legal section naming the AI model (`AIService.modelDisplayName`, read from the same constant the API call uses) and the e-signature path (`Secrets.signingBackend`).
- [ ] Profile needs from the owner: App Store Connect subscription products (until then the plan always reads "Free"), Terms and Privacy Policy URLs in `LegalLinks` (rows hide while nil; the App Store requires a privacy policy), and the Sign in with Apple capability registered for the App ID — automatic signing does this on the first device build from Xcode. `Handshake.entitlements` lives at the repo root for the same reason as `Info.plist`.
- [x] The AI panel's "Working on it…" spinner is a `ThinkingIndicator` (Nov 6): a breathing sparkle and shimmering status text stepping through stages ("Looking for similar templates…"). The stages are timed, not real progress — the API call isn't streamed — so they advance every 2.4 s and hold on the last rather than loop. Reduce Motion turns off the shimmer.
- [x] **Localised** (Nov 8) into Traditional Chinese (zh-Hant), Simplified Chinese (zh-Hans), Japanese, Korean, Spanish, French and German. `Handshake/Localizable.xcstrings` (176 strings) and `Handshake/InfoPlist.xcstrings` (the three permission prompts). SwiftUI literals (`Text("…")`, `Button("…")`) localise on their own; anything that travels as a `String` (component titles, accessibility labels, errors, the AI's canned replies, template prompts) is wrapped in `String(localized:)`. **Add new strings the same way**, then add them to the catalog (Xcode adds extracted keys when you build in the IDE; `xcodebuild` doesn't). Rules the translations follow: never "legally binding"; brand names untouched; Apple's own terms (e.g. 面容 ID in zh-Hans). Translations were machine-written by Claude: worth a native-speaker pass before release, especially the legal footer and consent line.
- **The AI writes contracts in the language of the request.** The prompt keeps `TITLE:`, `---`, `[Signature]`, `[Date]` untranslated (the app parses them) and puts everything else, role labels included, in that language. Role detection (`SignatureSlots.parseRole`) now accepts the full-width colon `：` and caseless scripts, so "房東：" gives a "房東" tab in the signing screen. Template prompts on Home are translated too, so tapping one in Japanese drafts a Japanese contract.
- Test a language without changing the simulator: `xcrun simctl launch <udid> com.weihsun.Handshake -AppleLanguages "(zh-Hant)" -AppleLocale zh_TW`.
- [x] Photos added to a contract are saved with it (Nov 7). They were built from `image` alone, which RTFD drops on save, so they vanished on reopen. Now `NSTextAttachment(data:ofType:)` with a JPEG (long edge ≤ 1200 px, quality 0.75): ~270 KB a photo. Setting `image` as well makes iOS re-encode it as PNG (~4 MB). Photos still don't reach the recipient — the link carries markdown only (see below).
- [x] Picking a photo or file closed the whole workspace. The UIKit picker bridges sat inside a `.sheet` and dismissed themselves, and SwiftUI's own dismiss then took the fullScreenCover with it. Replaced with SwiftUI's `.photosPicker` and `.fileImporter`.
- [ ] The iOS 26.3 simulator runtime renders no colour emoji (template icons show as `[?]`). Test on 26.5+
- [ ] A recipient sees the markdown rendering, not the sender's rich-text edits — the RTFD is deliberately excluded from the link payload for size. If that matters, the fix is a real transport (backend or `.fileImporter` with an `.rtfd` attachment), not a bigger link.
- [x] The stamped signature block and the field boxes were soft on Retina — they render at 3× now, sized by `attachmentSizes` (§6)
- [x] `PrimaryPillButton` in the nav bar rendered clamped ("S e" wrapped over two lines) — first patched with `lineLimit(1)` + `fixedSize`, then superseded by `ToolbarPillButton` (system glass); see §6
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
