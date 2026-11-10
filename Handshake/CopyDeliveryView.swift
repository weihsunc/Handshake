import SwiftUI
import MessageUI
import UniformTypeIdentifiers

struct CopyDeliveryView: View {
    let contract: GeneratedContract
    @Environment(\.dismiss) private var dismiss
    @State private var active: CopyDelivery?
    @State private var stagedFile: URL?
    @State private var sharedRecipient: CopyRecipient?
    @State private var confirmRecipient: CopyRecipient?
    @State private var deliveryFailed = false
    @State private var showError = false

    private var current: GeneratedContract { ContractStore.shared.contract(id: contract.id) ?? contract }

    var body: some View {
        NavigationStack {
            List {
                ForEach(current.copyRecipients) { person in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name)
                            Text(person.address).font(.footnote).foregroundStyle(Color.secondaryInk)
                        }
                        Spacer(minLength: 12)
                        if person.sentAt != nil {
                            Label("Sent", image: "ph-check").font(.footnote).foregroundStyle(Color.secondaryInk)
                        } else {
                            Button("Send") { prepare(for: person) }
                                .accessibilityLabel(Text("Send signed copy to \(person.name)"))
                                .disabled(active != nil || !current.canSendCCCopies)
                        }
                    }
                }
            }
            .navigationTitle("Send Copies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $active, onDismiss: deliveryClosed) { delivery in
                CopyComposeView(delivery: delivery, title: contract.title) { outcome in
                    switch outcome {
                    case .sent: markSent(delivery.person)
                    case .shared: sharedRecipient = delivery.person
                    case .failed: deliveryFailed = true
                    case .cancelled: break
                    }
                    active = nil
                }
            }
            .alert("Did you send it?", isPresented: Binding(get: { confirmRecipient != nil },
                                                             set: { if !$0 { confirmRecipient = nil } }),
                   presenting: confirmRecipient) { person in
                Button("Yes, mark as sent") { markSent(person) }
                Button("Not yet", role: .cancel) { }
            } message: { person in
                Text("Only mark it sent if you shared the PDF with \(person.name).")
            }
            .alert("Couldn't send the PDF", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Open the signed contract and try again.")
            }
        }
    }

    private func prepare(for person: CopyRecipient) {
        let snapshot = current
        guard active == nil, snapshot.canSendCCCopies,
              snapshot.copyRecipients.contains(where: { $0.id == person.id && $0.sentAt == nil }) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let pdf = try CompletedContractPDF.render(snapshot)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent(String(localized: "Signed copy")).appendingPathExtension("pdf")
            try pdf.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            stagedFile = file
            active = CopyDelivery(person: person, pdf: pdf, file: file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            showError = true
        }
    }

    private func markSent(_ person: CopyRecipient) {
        ContractStore.shared.update(id: contract.id) { stored in
            guard stored.canSendCCCopies, let i = stored.copyRecipients.firstIndex(where: { $0.id == person.id }) else { return }
            stored.copyRecipients[i].sentAt = .now
        }
    }

    private func deliveryClosed() {
        if let stagedFile { try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent()) }
        stagedFile = nil
        confirmRecipient = sharedRecipient
        sharedRecipient = nil
        if deliveryFailed { showError = true; deliveryFailed = false }
    }
}

private struct CopyDelivery: Identifiable {
    var id: UUID { person.id }
    let person: CopyRecipient
    let pdf: Data
    let file: URL
}

private struct CopyComposeView: UIViewControllerRepresentable {
    enum Outcome { case sent, shared, cancelled, failed }
    let delivery: CopyDelivery
    let title: String
    var onFinish: (Outcome) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let filename = delivery.file.lastPathComponent
        let message = String(localized: "The signed copy of \(title) is attached for your records.")
        switch ReplyChannel.best(for: delivery.person.address) {
        case .mail(let email):
            let mail = MFMailComposeViewController()
            mail.setToRecipients([email])
            mail.setSubject(String(localized: "Signed copy of \(title)"))
            mail.setMessageBody(message, isHTML: false)
            mail.addAttachmentData(delivery.pdf, mimeType: "application/pdf", fileName: filename)
            mail.mailComposeDelegate = context.coordinator
            return mail
        case .sms(let phone) where MFMessageComposeViewController.canSendAttachments():
            let sms = MFMessageComposeViewController()
            if sms.addAttachmentData(delivery.pdf, typeIdentifier: UTType.pdf.identifier, filename: filename) {
                sms.recipients = [phone]
                sms.body = message
                sms.messageComposeDelegate = context.coordinator
                return sms
            }
        default: break
        }
        let share = UIActivityViewController(activityItems: [delivery.file], applicationActivities: nil)
        share.completionWithItemsHandler = { _, completed, _, error in
            onFinish(error != nil ? .failed : completed ? .shared : .cancelled)
        }
        return share
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onFinish: (Outcome) -> Void
        init(onFinish: @escaping (Outcome) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent ? .sent : result == .failed ? .failed : .cancelled)
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result == .sent ? .sent : result == .failed ? .failed : .cancelled)
        }
    }
}
