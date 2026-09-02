import SwiftUI
import MessageUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SendFlowView
// ─────────────────────────────────────────────────────────────────────────────

struct SendFlowView: View {

    let contract: GeneratedContract
    @Environment(\.dismiss) private var dismiss

    @State private var recipients: [Recipient] = [Recipient()]
    @State private var activeSheet: ActiveSheet? = nil
    @State private var didSend: Bool = false
    @State private var askedAboutShare: Bool = false

    private enum ActiveSheet: Identifiable {
        case sms, mail, activity
        var id: Self { self }
    }

    // A recipient counts as valid once it has a name + at least one contact method
    private var validRecipients: [Recipient] {
        recipients.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            (!$0.email.trimmingCharacters(in: .whitespaces).isEmpty ||
             !$0.phone.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var canSend: Bool { !validRecipients.isEmpty }

    private var phoneNumbers: [String] {
        validRecipients.compactMap {
            let p = $0.phone.trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? nil : p
        }
    }

    private var emailAddresses: [String] {
        validRecipients.compactMap {
            let e = $0.email.trimmingCharacters(in: .whitespaces)
            return e.isEmpty ? nil : e
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Body
    // ─────────────────────────────────────────────────────────────────────────

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($recipients) { $recipient in
                        RecipientCard(
                            recipient: $recipient,
                            canDelete: recipients.count > 1,
                            onDelete: { recipients.removeAll { $0.id == recipient.id } }
                        )
                    }

                    Button {
                        recipients.append(Recipient())
                    } label: {
                        Label("Add Recipient", systemImage: "plus.circle.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color(red: 76/255, green: 0, blue: 255/255))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .background(Color(red: 0.98, green: 0.98, blue: 0.98).ignoresSafeArea())
            .navigationTitle("Send for Signing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color(.label))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    PurplePillButton(title: "Send") { startSend() }
                        .opacity(canSend ? 1 : 0.4)
                        .allowsHitTesting(canSend)
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .sms:
                MessageComposeView(recipients: phoneNumbers, body: smsBody) { result in
                    if result == .sent { didSend = true }
                    activeSheet = nil
                    if !emailAddresses.isEmpty && MFMailComposeViewController.canSendMail() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeSheet = .mail
                        }
                    } else {
                        finalize()
                    }
                }
            case .mail:
                MailComposeView(
                    toRecipients: emailAddresses,
                    subject: mailSubject,
                    body: mailBody
                ) { result in
                    if result == .sent || result == .saved { didSend = true }
                    activeSheet = nil
                    finalize()
                }
            case .activity:
                // Fallback for simulator / devices where compose sheets are
                // unavailable. One combined string, not [subject, body] — two
                // items makes the share sheet describe them as "2 Images" and
                // hand targets two separate payloads.
                ActivityView(activityItems: [shareText]) { completed in
                    activeSheet = nil
                    if completed {
                        // A share completed, but iOS won't say whether it was
                        // actually delivered (it could have been "Copy"), so
                        // confirm rather than assume.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            askedAboutShare = true
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .alert("Did you send it?", isPresented: $askedAboutShare) {
            Button("Yes, mark as sent") { didSend = true; finalize() }
            Button("Not yet", role: .cancel) { }
        } message: {
            Text("Handshake can't confirm delivery through the share sheet. Marking it sent moves it to Pending Signature.")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Send trigger
    // ─────────────────────────────────────────────────────────────────────────

    private func startSend() {
        let canSMS  = !phoneNumbers.isEmpty  && MFMessageComposeViewController.canSendText()
        let canMail = !emailAddresses.isEmpty && MFMailComposeViewController.canSendMail()

        if canSMS       { activeSheet = .sms      }
        else if canMail { activeSheet = .mail     }
        else            { activeSheet = .activity }
    }

    /// Called once the compose flow finishes. If anything actually went out,
    /// mark the contract as sent (status + recipients + timestamp) and persist.
    private func finalize() {
        if didSend {
            ContractStore.shared.markSent(id: contract.id, recipients: validRecipients)
        }
        dismiss()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Message bodies
    // ─────────────────────────────────────────────────────────────────────────

    // handshake://sign/<id> — requires the URL scheme registered in Info.plist
    private var signingLink: String { "handshake://sign/\(contract.id.uuidString)" }

    private var smsBody: String {
        "You've been invited to sign \"\(contract.title)\". Open in Handshake to review and sign with Face ID:\n\(signingLink)"
    }

    private var mailSubject: String { "Please sign: \(contract.title)" }

    /// Single payload for the share-sheet fallback — subject and body together,
    /// so the sheet has one item to describe and hand on.
    private var shareText: String { "\(mailSubject)\n\n\(mailBody)" }

    private var mailBody: String {
        """
        Hi,

        You've been invited to review and sign the following agreement:

        \(contract.title)

        Tap the link below to open it in Handshake and sign with Face ID:
        \(signingLink)

        This link is unique to you — please do not forward it.
        """
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RecipientCard
// ─────────────────────────────────────────────────────────────────────────────

private struct RecipientCard: View {
    @Binding var recipient: Recipient
    var canDelete: Bool
    var onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Text("Recipient")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                    .textCase(.uppercase)
                Spacer()
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Name
            HStack(spacing: 12) {
                Image(systemName: "person")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField("Full name", text: $recipient.name)
                    .font(.system(size: 17))
                    .textContentType(.name)
                    .keyboardType(.default)
                    .submitLabel(.next)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().padding(.leading, 48)

            // Email
            HStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField("Email", text: $recipient.email)
                    .font(.system(size: 17))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().padding(.leading, 48)

            // Phone
            HStack(spacing: 12) {
                Image(systemName: "phone")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField("Phone number", text: $recipient.phone)
                    .font(.system(size: 17))
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MessageComposeView  (MFMessageComposeViewController bridge)
// ─────────────────────────────────────────────────────────────────────────────

private struct MessageComposeView: UIViewControllerRepresentable {
    var recipients: [String]
    var body: String
    var onFinish: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MailComposeView  (MFMailComposeViewController bridge)
// ─────────────────────────────────────────────────────────────────────────────

private struct MailComposeView: UIViewControllerRepresentable {
    var toRecipients: [String]
    var subject: String
    var body: String
    var onFinish: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(toRecipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    SendFlowView(contract: GeneratedContract(
        id: UUID(),
        title: "Non-Disclosure Agreement",
        content: "This NDA is entered into between the parties..."
    ))
}
