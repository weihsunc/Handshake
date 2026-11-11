import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DocuSeal sync
//
// Someone who signs in a browser (DocuSeal's page) sends no link back, so the
// sender's phone asks DocuSeal instead: for each contract it sent through
// DocuSeal and is still waiting on, who has signed? Each new signer's box is
// marked signed on the sender's copy, which moves to Signed when every box is.
//
// It also finishes the sender's own part if that didn't reach DocuSeal when
// they sent (they signed with Face ID first; the network can drop it).
//
// Runs when Contracts opens and when the app comes to the front. Quiet on
// failure: the next run tries again.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum DocuSealSync {
    private static var running = false

    static func refresh() async {
        guard BackendClient.isConfigured, !running else { return }
        running = true
        defer { running = false }

        let waiting = ContractStore.shared.contracts.filter {
            !$0.isIncoming && $0.status == .sent && $0.providerRef?.backend == .docuseal
        }
        for c in waiting {
            guard let ref = c.providerRef,
                  let submitters = try? await SigningProviders.docuSealStatus(ref: ref) else { continue }
            let slots = c.signatureSlots()
            func slot(for role: String) -> Int? {
                slots.firstIndex { $0.role == role } ?? ref.roles?.firstIndex(of: role)
            }

            var signed: [PartySignature] = []
            for s in submitters {
                guard let at = s.completedAt, let i = slot(for: s.role), c.signature(forSlot: i) == nil else { continue }
                signed.append(PartySignature(slot: i, role: s.role,
                                             name: s.name.isEmpty ? s.role : s.name,
                                             signedAt: at,
                                             hash: "docuseal:\(ref.documentId):\(s.id)",
                                             method: "DocuSeal"))
            }

            // The sender's Face ID signature that DocuSeal hasn't recorded yet.
            for own in c.signatures where own.method != "DocuSeal" && own.role != nil && own.role == c.senderRole {
                guard let role = own.role,
                      submitters.contains(where: { $0.role == role && $0.completedAt == nil }) else { continue }
                let stamp = SignatureStamp(signerName: own.name, signedAt: own.signedAt, hash: own.hash, method: own.method)
                try? await SigningProviders.completeDocuSeal(ref: ref, role: role, signerName: own.name,
                                                             stamp: stamp, signedDate: own.date,
                                                             consentText: SigningView.consentText)
            }

            guard !signed.isEmpty else { continue }
            ContractStore.shared.update(id: c.id) { c in
                c.merge(signatures: signed)
                c.refreshCompletion()
            }
        }
    }
}
