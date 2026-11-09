import ContactsUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Contact picking
//
// The system contact picker, for choosing who signs. It runs out of process
// and hands back only what's picked, so it needs no Contacts permission and
// no usage string.
//
// Presented from UIKit on top of whatever is showing: wrapped in a SwiftUI
// .sheet, CNContactPickerViewController tends to show blank or close itself.
//
// A contact with exactly one email or phone number is picked with one tap;
// one with several opens their card so the sender taps the one to use.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum ContactPicking {

    /// Calls back with the contact's full name and the email or phone chosen.
    static func pick(_ done: @escaping (_ name: String, _ contact: String) -> Void) {
        let picker = CNContactPickerViewController()
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0 OR phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(format: "emailAddresses.@count + phoneNumbers.@count == 1")
        let delegate = Delegate(done)
        current = delegate          // the picker holds its delegate weakly
        picker.delegate = delegate
        topViewController()?.present(picker, animated: true)
    }

    private static var current: Delegate?

    private final class Delegate: NSObject, CNContactPickerDelegate {
        let done: (String, String) -> Void
        init(_ done: @escaping (String, String) -> Void) { self.done = done }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let value = contact.emailAddresses.first.map { String($0.value) }
                     ?? contact.phoneNumbers.first?.value.stringValue ?? ""
            finish(contact, value)
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            let value: String
            if let email = property.value as? NSString { value = email as String }
            else if let phone = property.value as? CNPhoneNumber { value = phone.stringValue }
            else { value = "" }
            finish(property.contact, value)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            ContactPicking.current = nil
        }

        private func finish(_ contact: CNContact, _ value: String) {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            done(name, value)
            ContactPicking.current = nil
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}
