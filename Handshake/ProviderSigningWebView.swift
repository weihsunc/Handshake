import SwiftUI
import WebKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ProviderSigningWebView  (Path B)
// SignWell's embedded signing page, shown inside the app after Face ID.
// SignWell posts a message when signing finishes; we also poll status on
// dismiss so a missed message can't leave the contract stuck in Pending.
// ─────────────────────────────────────────────────────────────────────────────

struct ProviderSigningWebView: View {
    let url: URL
    var onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SigningWebView(url: url, onFinished: {
                onFinished()
                dismiss()
            })
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onFinished(); dismiss() }
                }
            }
        }
    }
}

private struct SigningWebView: UIViewRepresentable {
    let url: URL
    var onFinished: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "handshake")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onFinished: () -> Void
        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

        // SignWell's embedded page emits a "completed" event to its parent;
        // the app-side hook is a redirect. Treat either as done.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url?.absoluteString.lowercased(),
               u.contains("completed") || u.contains("handshake://signed") {
                onFinished()
            }
            decisionHandler(.allow)
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if (m.body as? String)?.lowercased().contains("completed") == true { onFinished() }
        }
    }
}
