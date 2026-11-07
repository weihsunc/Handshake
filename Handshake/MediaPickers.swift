import SwiftUI
import UIKit

// ───────────────────────────────────────────────────────────────────────────
// MARK: - Media helpers
//
// The pickers themselves are SwiftUI's `.photosPicker` and `.fileImporter`
// (ContractWorkspaceView). The UIKit bridges that used to live here dismissed
// themselves inside a .sheet, and SwiftUI's second dismiss closed the
// workspace.
// ───────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Photo downscaling
// A camera photo is ~12 MP; a contract shows it at screen width. The JPEG is
// stored inside the contract's RTFD, so keep it to a sensible size.
// ─────────────────────────────────────────────────────────────────────────────

extension UIImage {
    /// The image with its long edge at most `maxPixels`, orientation baked in.
    func downscaled(maxPixels: CGFloat) -> UIImage {
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let factor = min(1, maxPixels / max(px.width, px.height, 1))
        let target = CGSize(width: (px.width * factor).rounded(), height: (px.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
