import AppIntents
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Siri: "Make a contract with Handshake"
//
// An App Shortcut, so it works with no setup: Siri asks what the contract is
// for, then opens the app on a new draft of it. (iOS 27's Siri can do more —
// pass what's on screen into an intent — see HANDOFF "Siri".)
// ─────────────────────────────────────────────────────────────────────────────

struct CreateContractIntent: AppIntent {
    static let title: LocalizedStringResource = "Make a contract"
    static let description = IntentDescription("Describe a deal and Handshake drafts the contract.")
    static let openAppWhenRun = true

    @Parameter(title: "What it's for",
               requestValueDialog: IntentDialog("What's the contract for?"))
    var details: String

    @MainActor
    func perform() async throws -> some IntentResult {
        NewDraftRouter.shared.open(PendingDraft(prompt: details))
        return .result()
    }
}

struct HandshakeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateContractIntent(),
            phrases: [
                "Make a contract with \(.applicationName)",
                "Create a contract with \(.applicationName)",
                "Draft a contract in \(.applicationName)",
                "Start a \(.applicationName) contract",
            ],
            shortTitle: "Make a contract",
            systemImageName: "signature"
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - New-draft router
// How things outside Home (Siri, the share extension's inbox) ask Home to
// open a new draft. Home watches `pending` and presents the workspace.
// ─────────────────────────────────────────────────────────────────────────────

struct PendingDraft: Identifiable, Equatable {
    let id = UUID()
    var prompt: String = ""
    var source: DraftSource? = nil
    /// Show the Start-from sheet filled in (something shared to Handshake),
    /// rather than drafting straight away.
    var review: Bool = false
    var thumbnails: [UIImage] = []
}

@Observable
final class NewDraftRouter {
    static let shared = NewDraftRouter()
    var pending: PendingDraft? = nil
    private init() {}

    func open(_ draft: PendingDraft) { pending = draft }
}
