// CI check: opens each Word file in docs/ the way iPhone previews show it (Files, Mail, WhatsApp:
// Quick Look, which WKWebView uses for Word files too) and saves, for each picture, where it lands
// and which lines of text it covers, the converted HTML, and screenshots: the top of the document
// and each picture with the text around it.
import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

@objc(QuickLookCheckSceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var check: Check?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        let check = Check(window: window)
        self.check = check
        Task { @MainActor in
            await check.run()
        }
    }
}

@MainActor
final class Check: NSObject, WKNavigationDelegate {
    let window: UIWindow
    let host = UIViewController()
    let web: WKWebView
    let out: URL
    var files: [URL] = []
    var loading: CheckedContinuation<String, Never>?
    var generation = 0
    var logText = ""

    init(window: UIWindow) {
        self.window = window
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        out = docs.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        web = WKWebView(frame: window.bounds, configuration: WKWebViewConfiguration())
        super.init()
        web.navigationDelegate = self
        host.view.backgroundColor = .white
        web.frame = host.view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(web)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let folder = Bundle.main.bundleURL.appendingPathComponent("docs", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        files = found.filter { $0.pathExtension.lowercased() == "docx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        log("files: \(files.count); \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
    }

    func log(_ s: String) {
        print(s)
        logText += s + "\n"
        try? logText.data(using: .utf8)?.write(to: out.appendingPathComponent("log.txt"))
    }

    func write(_ name: String, _ text: String) {
        try? text.data(using: .utf8)?.write(to: out.appendingPathComponent(name))
    }

    func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func run() async {
        await sleep(1)
        for (n, file) in files.enumerated() {
            await check(file, n: n + 1)
        }
        write("done.txt", "done")
        log("done")
        await sleep(1)
        exit(0)
    }

    func load(_ url: URL) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            loading = c
            generation += 1
            let g = generation
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            Task { @MainActor in
                await self.sleep(30)
                if self.generation == g {
                    self.finish("timeout")
                }
            }
        }
    }

    func finish(_ result: String) {
        guard let c = loading else { return }
        loading = nil
        c.resume(returning: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish("ok")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish("failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish("failed: \(error.localizedDescription)")
    }

    func js(_ code: String) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            web.evaluateJavaScript(code) { result, error in
                if let s = result as? String {
                    c.resume(returning: s)
                } else {
                    let message = String(describing: error).replacingOccurrences(of: "\"", with: "'")
                    c.resume(returning: "{\"error\": \"\(message)\"}")
                }
            }
        }
    }

    func snapshot(_ name: String) async {
        let data: Data? = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            web.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
                c.resume(returning: image?.pngData())
            }
        }
        if let data {
            try? data.write(to: out.appendingPathComponent(name))
        }
    }

    /// Each picture's box (CSS pixels, which Quick Look makes points) and the lines of text
    /// beside it: those whose middle lies within its height.
    static let measure = """
    (function () {
      function box(r) { return {x: Math.round(r.left + scrollX), y: Math.round(r.top + scrollY), w: Math.round(r.width), h: Math.round(r.height)}; }
      var lines = [];
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), node;
      while ((node = walker.nextNode())) {
        if (!node.data.trim()) continue;
        var r = document.createRange(); r.selectNodeContents(node);
        Array.prototype.forEach.call(r.getClientRects(), function (rect) {
          if (rect.width > 0) lines.push({box: box(rect), text: node.data.trim().slice(0, 60)});
        });
      }
      var images = Array.prototype.map.call(document.querySelectorAll('img'), function (el) {
        var b = box(el.getBoundingClientRect()), cs = getComputedStyle(el);
        var beside = lines.filter(function (l) { var m = l.box.y + l.box.h / 2; return m >= b.y && m <= b.y + b.h; })
                          .map(function (l) { return l.text + ' @' + l.box.x + ',' + l.box.y; }).slice(0, 8);
        return {box: b, position: cs.position, top: cs.top, left: cs.left, marginLeft: cs.marginLeft, marginTop: cs.marginTop, beside: beside};
      });
      return JSON.stringify({width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight, images: images}, null, 1);
    })()
    """

    func check(_ file: URL, n: Int) async {
        let name = "doc\(n)"
        web.scrollView.setZoomScale(1, animated: false)
        let result = await load(file)
        log("\(name) = \(file.lastPathComponent): \(result)")
        await sleep(2.5)
        let measured = await js(Check.measure)
        write("\(name).json", measured)
        write("\(name).html", await js("document.documentElement.outerHTML"))
        await snapshot("\(name)-top.png")
        let count = Int(await js("String(document.querySelectorAll('img').length)")) ?? 0
        for k in 0..<min(count, 12) {
            _ = await js("""
            (function () {
              var el = document.querySelectorAll('img')[\(k)], r = el.getBoundingClientRect();
              window.scrollTo(0, r.top + scrollY + r.height / 2 - innerHeight / 2);
              return 'ok';
            })()
            """)
            await sleep(0.8)
            await snapshot("\(name)-picture\(k + 1).png")
        }
    }
}
