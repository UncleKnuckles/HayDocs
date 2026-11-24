import UIKit
import WebKit

enum WebRenderError: LocalizedError {
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .failed(let text): return "Системный просмотрщик не открыл файл: \(text)"
        case .timeout: return "Системный просмотрщик не ответил."
        }
    }
}

/// Spreadsheets, slides and files the engine can't read: WebKit opens them (it shows Office files
/// itself) and its print layout makes the pages.
@MainActor
final class WebDocumentRenderer: NSObject, WKNavigationDelegate {
    static func render(fileAt url: URL, paper: PaperSize) async throws -> Data {
        let renderer = WebDocumentRenderer(paper: paper)
        return try await renderer.run(url)
    }

    private let paper: PaperSize
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var window: UIWindow?

    private init(paper: PaperSize) {
        self.paper = paper
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(origin: .zero, size: paper.size), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .white
    }

    private func run(_ url: URL) async throws -> Data {
        // Out of sight, but in a window, so WebKit lays the page out.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: -10_000, y: 0, width: paper.size.width, height: paper.size.height)
            window.isHidden = false
            window.alpha = 0.01
            window.isUserInteractionEnabled = false
            window.addSubview(webView)
            self.window = window
        }
        defer {
            webView.removeFromSuperview()
            window?.isHidden = true
            window = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                self?.finish(.failure(WebRenderError.timeout))
            }
        }
        // Office files are converted after the load event: give scripts and pictures a moment.
        try? await Task.sleep(nanoseconds: 800_000_000)
        return makePDF()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func makePDF() -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paperRect = CGRect(origin: .zero, size: paper.size)
        let printable = paperRect.insetBy(dx: 28, dy: 32)
        renderer.setValue(NSValue(cgRect: paperRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paperRect, nil)
        let count = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        for page in 0..<count {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WebRenderError.failed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WebRenderError.failed(error.localizedDescription)))
    }
}
