import Foundation
import AppKit

@main
struct BlankFieldsRegression {
    static func main() {
        let doc = NSMutableAttributedString(string: "Notify within [NUMBER] hours.\nPay within [NUMBER] days.\nEnd with [NUMBER] days notice.")
        let fields = SignatureSlots.blankFields(in: doc)
        precondition(fields.count == 3 && Set(fields.map(\.id)).count == 3)
        precondition(SignatureSlots.context(of: fields[1], in: doc) == "Pay within ____ days.")
        let highlights = SignatureSlots.fillFields([fields[0].id: "3", fields[1].id: "30"], fields: fields, in: doc)
        precondition(doc.string == "Notify within 3 hours.\nPay within 30 days.\nEnd with [NUMBER] days notice.")
        precondition(highlights.map { (doc.string as NSString).substring(with: $0) } == ["3", "30"])
        precondition(SignatureSlots.blankFields(in: doc).count == 1)

        let longLabel = "[LIST OF ACCESSORIES, e.g. battery, charger, memory card, lens cap, strap]"
        let longDoc = NSMutableAttributedString(string: "Include \(longLabel).")
        let longFields = SignatureSlots.blankFields(in: longDoc)
        precondition(longFields.count == 1)
        _ = SignatureSlots.fillFields([longFields[0].id: "battery and charger"], fields: longFields, in: longDoc)
        precondition(longDoc.string == "Include battery and charger.")

        let unicode = NSMutableAttributedString(string: "📷 通知 [日數] 天。\n付款 [日數] 天。")
        let unicodeFields = SignatureSlots.blankFields(in: unicode)
        _ = SignatureSlots.fillFields([unicodeFields[1].id: "七"], fields: unicodeFields, in: unicode)
        precondition(unicode.string == "📷 通知 [日數] 天。\n付款 七 天。")

        let signatures = NSAttributedString(string: "Name: [CLIENT NAME]\nCLIENT: [FULL NAME]\n[Signature]\n[Date]")
        precondition(SignatureSlots.blankFields(in: signatures).map(\.token) == ["[CLIENT NAME]"])

        let stale = NSMutableAttributedString(string: "Pay [AMOUNT].")
        let staleFields = SignatureSlots.blankFields(in: stale)
        stale.insert(NSAttributedString(string: "New: "), at: 0)
        precondition(SignatureSlots.fillFields([staleFields[0].id: "500"], fields: staleFields, in: stale).isEmpty)
        precondition(stale.string == "New: Pay [AMOUNT].")

        let formatted = NSMutableAttributedString(string: "Fee: [AMOUNT].", attributes: [.foregroundColor: NSColor.red])
        let formattedFields = SignatureSlots.blankFields(in: formatted)
        let ranges = SignatureSlots.fillFields([formattedFields[0].id: "250"], fields: formattedFields, in: formatted)
        precondition(formatted.attribute(.foregroundColor, at: ranges[0].location, effectiveRange: nil) as? NSColor == NSColor.red)
        print("Passed blank regressions: independent occurrences, context, long labels, UTF-16, signature exclusion, stale snapshots, formatting, highlights and remaining count.")
    }
}
