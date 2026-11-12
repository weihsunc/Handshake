import SwiftUI
import MessageUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MessageComposeView  (MFMessageComposeViewController bridge)
// ─────────────────────────────────────────────────────────────────────────────

struct MessageComposeView: UIViewControllerRepresentable {
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

struct MailComposeView: UIViewControllerRepresentable {
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
// MARK: - ReplyComposeSheet
//
// A message to ONE person — the sender, from a recipient: the signed copy, a
// decline, a request for changes. The sender's link says where to reply
// (`replyTo`), so this opens Messages or Mail already addressed to them.
// Without an address, or on a device that can't compose, it's the share
// sheet as before.
// ─────────────────────────────────────────────────────────────────────────────

enum ReplyOutcome { case sent, copied, cancelled }

enum ReplyChannel: Equatable {
    case sms(String), mail(String), share

    static func best(for address: String?) -> ReplyChannel {
        let a = (address ?? "").trimmingCharacters(in: .whitespaces)
        if a.contains("@") {
            return MFMailComposeViewController.canSendMail() ? .mail(a) : .share
        }
        if a.filter(\.isNumber).count >= 7 {
            return MFMessageComposeViewController.canSendText() ? .sms(a) : .share
        }
        return .share
    }
}

struct ReplyComposeSheet: View {
    let address: String?
    let subject: String
    let message: String
    var onFinish: (ReplyOutcome) -> Void

    var body: some View {
        switch ReplyChannel.best(for: address) {
        case .sms(let phone):
            MessageComposeView(recipients: [phone], body: message) { r in
                onFinish(r == .sent ? .sent : .cancelled)
            }
            .ignoresSafeArea()
        case .mail(let email):
            MailComposeView(toRecipients: [email], subject: subject, body: message) { r in
                onFinish(r == .sent ? .sent : .cancelled)
            }
            .ignoresSafeArea()
        case .share:
            ActivityView(activityItems: [message], onFinishActivity: { completed, type in
                onFinish(!completed ? .cancelled : type == .copyToPasteboard ? .copied : .sent)
            })
            .presentationDetents([.medium, .large])
        }
    }
}
