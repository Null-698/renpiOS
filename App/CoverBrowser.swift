import SwiftUI
import WebKit
import ImageIO

@MainActor
@Observable
final class CoverWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    var address: String
    var loading = false
    var imageURL: URL?
    var message: String?
    var candidate: Data?
    var saving = false

    init(url: URL) {
        address = url.absoluteString
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.load(URLRequest(url: url))
    }

    func navigate() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: input), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            message = "Enter a website address."
            return
        }
        web.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        imageURL = nil
        message = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        address = webView.url?.absoluteString ?? address
        let page = webView.url
        webView.evaluateJavaScript("document.images.length === 1 ? document.images[0].currentSrc : null") { [weak self] result, _ in
            guard self?.web.url == page,
                  let value = result as? String, let url = URL(string: value),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
            self?.imageURL = url
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(),
              ["https", "http", "about", "blob", "data"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else { completionHandler(nil); return }
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Open in Cover Browser", image: UIImage(systemName: "arrow.up.right")) { _ in
                    self?.web.load(URLRequest(url: url))
                }
            ])
        })
    }

    func previewImage() {
        guard let imageURL else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (file, response) = try await session.download(for: URLRequest(url: imageURL, timeoutInterval: 25))
                defer { try? FileManager.default.removeItem(at: file) }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      size <= 25 * 1024 * 1024 else {
                    throw URLError(.badServerResponse)
                }
                candidate = try CoverLookup.jpeg(from: file)
            } catch { message = "Open the full-size image first, then try Use Image again." }
        }
    }
}

private struct CoverWebView: UIViewRepresentable {
    let session: CoverWebSession
    func makeUIView(context: Context) -> WKWebView { session.web }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}

struct CoverBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: CoverWebSession
    let save: (Data) throws -> Void

    init(url: URL, save: @escaping (Data) throws -> Void) {
        _session = State(initialValue: CoverWebSession(url: url))
        self.save = save
    }

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Website address", text: $session.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { session.navigate() }
                    Button("Go", systemImage: "arrow.right") { session.navigate() }.labelStyle(.iconOnly)
                }
                .padding(12)
                if session.loading { ProgressView().progressViewStyle(.linear) }
                CoverWebView(session: session)
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(8)
                }
            }
            .navigationTitle("Private Cover Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { session.web.goBack() }
                    Button("Forward", systemImage: "chevron.right") { session.web.goForward() }
                    Spacer()
                    Button("Use Image", systemImage: "photo") { session.previewImage() }
                        .disabled(session.imageURL == nil || session.saving)
                }
            }
            .sheet(isPresented: Binding(get: { session.candidate != nil }, set: { if !$0 { session.candidate = nil } })) {
                VStack(spacing: 18) {
                    if let data = session.candidate, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                        Button("Use This Cover", systemImage: "checkmark") {
                            do {
                                try save(data)
                                dismiss()
                            } catch { session.message = error.localizedDescription; session.candidate = nil }
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button("Choose Another Image") { session.candidate = nil }
                }
                .padding(20)
                .presentationDragIndicator(.visible)
            }
        }
        .tint(amber)
    }
}
