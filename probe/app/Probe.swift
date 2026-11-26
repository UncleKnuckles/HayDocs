// Opens each .docx in docs/ the way iOS previews it (WKWebView converts it with QuickLook), measures
// where the pictures and the signature line land, saves the converted HTML and screenshots, then
// shows some of them in QLPreviewController for screenshots taken from outside (simctl).
import UIKit
import WebKit
import QuickLook

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

@objc(ProbeSceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var probe: Probe?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        let probe = Probe(window: window)
        self.probe = probe
        Task { @MainActor in
            await probe.run()
        }
    }
}

final class Source: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }
}

@MainActor
final class Probe: NSObject, WKNavigationDelegate {
    let window: UIWindow
    let host = UIViewController()
    let web: WKWebView
    let out: URL
    var files: [URL] = []
    var loading: CheckedContinuation<String, Never>?
    var generation = 0
    var qlSource: Source?
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
        files = found.filter { $0.pathExtension == "docx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        log("docs: \(files.count) in \(folder.path)")
        log("window: \(window.bounds), scale \(window.traitCollection.displayScale), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
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
        for file in files {
            await probe(file)
        }
        // QLPreviewController, as Files, Mail and WhatsApp show a document: one-page letters only
        // (the whole page fits on the screen).
        var n = 0
        for file in files where file.lastPathComponent.hasPrefix("q1_N1") || file.lastPathComponent.hasPrefix("q1_A_") {
            n += 1
            await quickLook(file, n: n)
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
        finish("fail: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish("fail provisional: \(error)")
    }

    func js(_ code: String) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            web.evaluateJavaScript(code) { result, error in
                if let s = result as? String {
                    c.resume(returning: s)
                } else {
                    c.resume(returning: "{\"error\": \"\(String(describing: error).replacingOccurrences(of: "\"", with: "'"))\"}")
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

    static let measure = """
    (function () {
      function box(r) { return {x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height}; }
      function chain(el) {
        var out = [];
        for (var p = el, i = 0; p && i < 8; p = p.parentElement, i++) {
          var cs = getComputedStyle(p);
          out.push(p.tagName + (p.id ? '#' + p.id : '') + (p.className && p.className.baseVal === undefined ? '.' + p.className : '') +
                   ' pos=' + cs.position + ' top=' + cs.top + ' left=' + cs.left + ' style="' + (p.getAttribute('style') || '').slice(0, 300) + '" box=' + JSON.stringify(box(p.getBoundingClientRect())));
        }
        return out;
      }
      var res = {href: location.href, inner: [innerWidth, innerHeight], scroll: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
                 dpr: devicePixelRatio, iframes: document.querySelectorAll('iframe').length};
      var viewport = document.querySelector('meta[name=viewport]');
      res.viewport = viewport ? viewport.getAttribute('content') : null;
      res.images = Array.prototype.map.call(document.querySelectorAll('img, svg, object, embed, canvas, image'), function (el) {
        return {tag: el.tagName, src: String(el.getAttribute('src') || el.getAttribute('href') || el.getAttribute('xlink:href') || '').slice(0, 120),
                box: box(el.getBoundingClientRect()), chain: chain(el)};
      });
      var marks = {}, wanted = ['Ստորագրություն', '____', 'Տնօրեն', '«24»', 'ՏԵՂԵԿԱՆՔ', 'Տեղեկանքում'];
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var node;
      while ((node = walker.nextNode())) {
        wanted.forEach(function (w) {
          var i = node.data.indexOf(w);
          if (i < 0) return;
          var r = document.createRange();
          r.setStart(node, i); r.setEnd(node, i + w.length);
          (marks[w] = marks[w] || []).push({box: box(r.getBoundingClientRect()), chain: chain(node.parentElement).slice(0, 4)});
        });
      }
      res.marks = marks;
      res.top = Array.prototype.slice.call(document.body.children, 0, 30).map(function (el) {
        return {tag: el.tagName, cls: String(el.className), style: (el.getAttribute('style') || '').slice(0, 300), box: box(el.getBoundingClientRect())};
      });
      return JSON.stringify(res, null, 1);
    })()
    """

    func probe(_ file: URL) async {
        let name = file.deletingPathExtension().lastPathComponent
        web.scrollView.setZoomScale(1, animated: false)
        let result = await load(file)
        log("\(name): \(result)")
        await sleep(2.5)
        let measured = await js(Probe.measure)
        write("\(name).json", measured)
        let html = await js("document.documentElement.outerHTML")
        write("\(name).html", html)
        log("\(name): zoom \(web.scrollView.zoomScale) content \(web.scrollView.contentSize)")
        await snapshot("\(name)-top.png")
        // The signature line in the middle of the screen.
        _ = await js("""
        (function () {
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), node;
          while ((node = walker.nextNode())) {
            var i = node.data.indexOf('Ստորագրություն');
            if (i >= 0) {
              var r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + 3);
              var b = r.getBoundingClientRect();
              window.scrollTo(0, b.top + window.scrollY - innerHeight / 2);
              return 'ok';
            }
          }
          return 'none';
        })()
        """)
        await sleep(1)
        await snapshot("\(name)-sig.png")
    }

    func quickLook(_ file: URL, n: Int) async {
        let name = file.deletingPathExtension().lastPathComponent
        let source = Source(url: file)
        qlSource = source
        let ql = QLPreviewController()
        ql.dataSource = source
        ql.modalPresentationStyle = .fullScreen
        host.present(ql, animated: false)
        await sleep(6)
        write("ql-ready-\(n).txt", name)
        let shot = out.appendingPathComponent("ql-shot-\(n).txt")
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: shot.path) { break }
            await sleep(0.5)
        }
        log("ql \(n) \(name)")
        ql.dismiss(animated: false)
        await sleep(1)
        qlSource = nil
    }
}
