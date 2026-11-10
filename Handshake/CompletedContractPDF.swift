import UIKit

/// The sender's rich document and its recorded signatures, laid out for print.
/// The provider PDF takes a separate, text-only path.
@MainActor
enum CompletedContractPDF {
    enum ExportError: Error { case incomplete, layout }

    static func render(_ contract: GeneratedContract) throws -> Data {
        guard contract.canSendCCCopies else { throw ExportError.incomplete }
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let column = page.insetBy(dx: 72, dy: 72)
        let body = contract.displayBody(signatureWidth: column.width)
        body.insert(NSAttributedString(string: contract.title + "\n\n", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 22)
        ]), at: 0)
        let fullRange = NSRange(location: 0, length: body.length)
        body.addAttribute(.foregroundColor, value: UIColor.black, range: fullRange)
        body.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if attachment.image == nil, let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents {
                attachment.image = UIImage(data: data)
            }
            let bounds = attachment.bounds
            let size = bounds.width > 0 ? bounds.size : (attachment.image?.size ?? .zero)
            guard size.width > 0, size.height > 0 else { return }
            // Leave enough room for the attachment's line fragment as well.
            let scale = min(1, column.width / size.width, (column.height - 36) / size.height)
            attachment.bounds = CGRect(origin: bounds.origin,
                                       size: CGSize(width: size.width * scale, height: size.height * scale))
        }

        let storage = NSTextStorage(attributedString: body)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var pages: [NSRange] = []
        var cursor = 0
        while cursor < layout.numberOfGlyphs {
            let container = NSTextContainer(size: column.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            guard range.location == cursor, range.length > 0 else { throw ExportError.layout }
            pages.append(range)
            cursor = NSMaxRange(range)
        }

        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for range in pages {
                context.beginPage()
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(page)
                layout.drawBackground(forGlyphRange: range, at: column.origin)
                layout.drawGlyphs(forGlyphRange: range, at: column.origin)
            }
        }
    }
}
