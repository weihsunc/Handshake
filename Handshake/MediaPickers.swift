import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// ───────────────────────────────────────────────────────────────────────────
// MARK: - Media pickers
//
// UIKit picker bridges used by the editor's formatting toolbar. Extracted from
// the former ContractEditorView.swift.
// ───────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Photo Picker  (PHPickerViewController bridge)
// Presents the system photo library and delivers a single UIImage via callback.
// ─────────────────────────────────────────────────────────────────────────────

struct PhotoPickerView: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImagePicked: onImagePicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        init(onImagePicked: @escaping (UIImage) -> Void) { self.onImagePicked = onImagePicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let img = object as? UIImage else { return }
                DispatchQueue.main.async { self.onImagePicked(img) }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document Picker  (UIDocumentPickerViewController bridge)
// Delivers the picked file URL so callers can insert an attachment placeholder.
// ─────────────────────────────────────────────────────────────────────────────

struct DocumentPickerView: UIViewControllerRepresentable {
    var onFilePicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.data, .pdf, .image, .plainText]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFilePicked: onFilePicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFilePicked: (URL) -> Void
        init(onFilePicked: @escaping (URL) -> Void) { self.onFilePicked = onFilePicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            DispatchQueue.main.async { self.onFilePicked(url) }
        }
    }
}
