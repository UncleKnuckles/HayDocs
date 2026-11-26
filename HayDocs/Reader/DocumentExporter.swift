import PDFKit
import PencilKit
import UIKit

/// The Pencil drawing of a page as pictures for the document engine. Strokes that lie close
/// together (a signature, a word, a tick) make one picture with no background, and each picture
/// says where on the page it goes, in page points from the top left corner. The engine ties each
/// one to the text it was drawn on, so it stays there when Word lays the text out its own way.
enum InkPictures {
    /// Strokes this close (page points) go in one picture.
    static let gap: CGFloat = 12
    /// Room around the ink (page points), so no edge of a line is cut off.
    static let padding: CGFloat = 2
    /// Pixels per page point: about 290 dpi, sharp in print.
    static let pixelsPerPoint: CGFloat = 4
    static let mostPixels: CGFloat = 6_000_000

    /// One picture: strokes of the drawing (in drawing order) and the canvas rectangle it shows.
    struct Group {
        var strokes: [Int]
        var rect: CGRect
        /// Marker strokes only: put behind the text, as a highlighter is.
        var behind: Bool
    }

    /// The canvas lies over the whole page: canvas points times these are page points.
    static func scales(canvasSize: CGSize, pageSize: CGSize) -> (CGFloat, CGFloat) {
        (pageSize.width / max(canvasSize.width, 1), pageSize.height / max(canvasSize.height, 1))
    }

    /// Strokes grouped by nearness, markers apart from the rest; groups don't overlap.
    static func groups(of drawing: PKDrawing, canvasSize: CGSize, pageSize: CGSize) -> [Group] {
        let (sx, sy) = scales(canvasSize: canvasSize, pageSize: pageSize)
        let canvas = CGRect(origin: .zero, size: canvasSize)
        // Half the gap on each side, in canvas points.
        let gx = gap / 2 / max(sx, 1e-6)
        let gy = gap / 2 / max(sy, 1e-6)
        let grown = { (r: CGRect) in r.insetBy(dx: -gx, dy: -gy) }

        var items: [(index: Int, bounds: CGRect, behind: Bool)] = []
        for (index, stroke) in drawing.strokes.enumerated() {
            let bounds = stroke.renderBounds
            guard !bounds.isNull, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.intersects(canvas) else { continue }
            items.append((index, bounds, stroke.ink.inkType == .marker))
        }

        // Strokes whose boxes come within the gap of each other, joined.
        var parent = Array(items.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for a in items.indices {
            let ra = grown(items[a].bounds)
            for b in items.indices where b > a && items[b].behind == items[a].behind {
                if ra.intersects(grown(items[b].bounds)) {
                    let (top, other) = (root(a), root(b))
                    if top != other { parent[other] = top }
                }
            }
        }
        var byRoot: [Int: Group] = [:]
        var order: [Int] = []
        for i in items.indices {
            let r = root(i)
            if var group = byRoot[r] {
                group.strokes.append(items[i].index)
                group.rect = group.rect.union(items[i].bounds)
                byRoot[r] = group
            } else {
                byRoot[r] = Group(strokes: [items[i].index], rect: items[i].bounds, behind: items[i].behind)
                order.append(r)
            }
        }
        var groups = order.compactMap { byRoot[$0] }

        // Groups whose boxes still come close (a stroke around another's box) become one, so no
        // two pictures of a kind cover each other.
        var merged = true
        while merged {
            merged = false
            search: for a in groups.indices {
                for b in groups.indices where b > a && groups[b].behind == groups[a].behind {
                    if grown(groups[a].rect).intersects(grown(groups[b].rect)) {
                        groups[a].strokes += groups[b].strokes
                        groups[a].rect = groups[a].rect.union(groups[b].rect)
                        groups.remove(at: b)
                        merged = true
                        break search
                    }
                }
            }
        }
        for i in groups.indices { groups[i].strokes.sort() }
        // Highlights first, so ink drawn over them stays on top where pictures meet.
        return groups.filter(\.behind) + groups.filter { !$0.behind }
    }

    /// The page's pictures as PNG files in `folder`, for the engine's "drawings".
    static func pictures(of drawing: PKDrawing, page: Int, canvasSize: CGSize, pageSize: CGSize,
                         into folder: URL) -> [[String: Any]] {
        let (sx, sy) = scales(canvasSize: canvasSize, pageSize: pageSize)
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let strokes = drawing.strokes
        var out: [[String: Any]] = []
        for (n, group) in groups(of: drawing, canvasSize: canvasSize, pageSize: pageSize).enumerated() {
            var rect = group.rect.insetBy(dx: -padding / max(sx, 1e-6), dy: -padding / max(sy, 1e-6))
                .intersection(canvas)
            guard !rect.isNull, rect.width * sx >= 0.5, rect.height * sy >= 0.5 else { continue }
            // Pixels per canvas point; the picture's sides made whole pixels, so it maps exactly.
            var scale = pixelsPerPoint * max(sx, sy)
            scale = max(0.25, min(scale, sqrt(mostPixels / max(rect.width * rect.height, 1))))
            rect.size = CGSize(width: (rect.width * scale).rounded(.up) / scale,
                               height: (rect.height * scale).rounded(.up) / scale)
            let data: Data? = autoreleasepool {
                var image = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = PKDrawing(strokes: group.strokes.map { strokes[$0] }).image(from: rect, scale: scale)
                }
                return image.pngData()
            }
            let url = folder.appendingPathComponent("ink-\(page + 1)-\(n + 1).png")
            guard let data, (try? data.write(to: url)) != nil else {
                Log.info("export: picture \(n + 1) of page \(page + 1) not made")
                continue
            }
            out.append([
                "page": page,
                "x": Double(rect.minX * sx),
                "y": Double(rect.minY * sy),
                "width": Double(rect.width * sx),
                "height": Double(rect.height * sy),
                "path": url.path,
                "behind": group.behind,
            ])
        }
        return out
    }
}

enum ExportError: LocalizedError {
    case page(Int)

    var errorDescription: String? {
        switch self {
        case .page(let n): return "Не удалось нарисовать страницу \(n)."
        }
    }
}

/// Word (.docx) and ODT files with the drawings, and pictures of the pages.
///
/// A document whose pages the engine made from Word, ODT, RTF or text is laid out again: its text
/// stays text and each signature or mark becomes a picture tied to the text it was drawn on, which
/// Word and LibreOffice can move or delete.
/// Other documents (PDF, photos, scans, notebooks, tables and slides), and pages added in the app,
/// become pages that are pictures with the drawing in them.
@MainActor
enum DocumentExporter {
    enum Format: String {
        case docx, odt
    }

    struct Source {
        let entry: LibraryDocument
        let pdf: PDFDocument
        /// Drawings by page (pages with ink only) and the canvas size each was made on.
        let drawings: [Int: PKDrawing]
        let canvasSizes: [Int: CGSize]
        let original: URL?
    }

    /// The engine can lay the original out again as the pages were made.
    static func hasText(_ entry: LibraryDocument, original: URL?) -> Bool {
        guard original != nil else { return false }
        switch entry.kind {
        case .word, .odt, .rtf, .text, .html: break
        default: return false
        }
        if let made = entry.madeByEngine { return made }
        return !entry.notes.contains { $0.hasPrefix("Показано системным просмотрщиком") }
    }

    static func export(_ format: Format, source: Source, title: String, into folder: URL,
                       progress: @escaping (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ExportWork-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let output = folder.appendingPathComponent("\(title).\(format.rawValue)")
        let count = source.pdf.pageCount

        if let original = source.original, hasText(source.entry, original: original) {
            do {
                let input = try DocumentConverter.engineInput(for: original, kind: source.entry.kind, in: work).url
                var own = min(source.entry.sourcePages ?? count, count)
                var answer = try await withText(input: input, own: own, output: output, source: source, work: work,
                                                title: title, progress: progress)
                if source.entry.sourcePages == nil, answer.pages < own, !answer.skippedPages.isEmpty {
                    // Pages added before the app counted them: the pages after the file's own.
                    own = answer.pages
                    answer = try await withText(input: input, own: own, output: output, source: source, work: work,
                                                title: title, progress: progress)
                }
                if !answer.skippedPages.isEmpty {
                    Log.info("export: drawing not placed on pages \(answer.skippedPages.map { $0 + 1 })")
                }
                dumpForTests(output, source: source)
                return output
            } catch {
                Log.info("export with text failed (\(error.localizedDescription)), pages as pictures")
            }
        }

        let pictures = try await renderPictures(of: 0..<count, source: source, work: work, progress: progress)
        progress("Сохраняю…")
        _ = try await WordEngine.shared.export(input: nil, output: output, drawings: [], pictures: pictures, title: title)
        dumpForTests(output, source: source)
        return output
    }

    /// The original laid out again with the drawings on pages before `own`, and the pages from
    /// `own` on (added in the app) as pictures after its text.
    private static func withText(input: URL, own: Int, output: URL, source: Source, work: URL, title: String,
                                 progress: @escaping (String) -> Void) async throws -> WordEngine.ExportAnswer {
        var drawings: [[String: Any]] = []
        let inked = source.drawings.keys.sorted().filter { $0 < own }
        for (n, index) in inked.enumerated() {
            guard let drawing = source.drawings[index], let page = source.pdf.page(at: index) else { continue }
            progress("Готовлю рисунки: \(n + 1) из \(inked.count)")
            await Task.yield()
            let size = PDFExporter.displayRect(for: page).size
            drawings += InkPictures.pictures(of: drawing, page: index, canvasSize: source.canvasSizes[index] ?? size,
                                             pageSize: size, into: work)
        }
        let pictures = try await renderPictures(of: own..<source.pdf.pageCount, source: source, work: work, progress: progress)
        progress("Сохраняю…")
        if TestHooks.dumpEnabled, let json = try? JSONSerialization.data(withJSONObject: drawings, options: [.prettyPrinted, .sortedKeys]) {
            TestHooks.dump("export-\(ReaderController.safeFileName(source.entry.title))-\(output.pathExtension)-drawings.json", data: json)
        }
        return try await WordEngine.shared.export(input: input, output: output, drawings: drawings, pictures: pictures, title: title)
    }

    /// Pages as JPEG pictures with their drawings, for the engine: [path, width, height].
    private static func renderPictures(of pages: Range<Int>, source: Source, work: URL,
                                 progress: @escaping (String) -> Void) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for index in pages {
            guard let page = source.pdf.page(at: index) else { continue }
            progress("Готовлю страницы: \(index - pages.lowerBound + 1) из \(pages.count)")
            await Task.yield()
            let rect = PDFExporter.displayRect(for: page)
            let data: Data? = autoreleasepool {
                PDFExporter.pageImage(page, drawing: source.drawings[index], canvasSize: source.canvasSizes[index],
                                      scale: pictureScale(for: rect.size, most: 2.5))
                    .jpegData(compressionQuality: 0.85)
            }
            guard let data else { throw ExportError.page(index + 1) }
            let url = work.appendingPathComponent("page-\(index + 1).jpg")
            try data.write(to: url)
            out.append(["path": url.path, "width": Double(rect.width), "height": Double(rect.height)])
        }
        return out
    }

    /// Every page as a PNG picture with its drawing.
    static func pageImages(source: Source, title: String, into folder: URL,
                           progress: @escaping (String) -> Void) async throws -> [URL] {
        var urls: [URL] = []
        let count = source.pdf.pageCount
        for index in 0..<count {
            guard let page = source.pdf.page(at: index) else { continue }
            progress("Готовлю картинки: \(index + 1) из \(count)")
            await Task.yield()
            let size = PDFExporter.displayRect(for: page).size
            let data: Data? = autoreleasepool {
                PDFExporter.pageImage(page, drawing: source.drawings[index], canvasSize: source.canvasSizes[index],
                                      scale: pictureScale(for: size, most: 2))
                    .pngData()
            }
            guard let data else { throw ExportError.page(index + 1) }
            let url = folder.appendingPathComponent(count == 1 ? "\(title).png" : "\(title), стр. \(index + 1).png")
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// At most `most` pixels per point, and at most about 12 million pixels a page.
    private static func pictureScale(for size: CGSize, most: CGFloat) -> CGFloat {
        let area = max(size.width * size.height, 1)
        return min(most, max(0.5, sqrt(12_000_000 / area)))
    }

    private static func dumpForTests(_ output: URL, source: Source) {
        guard TestHooks.dumpEnabled, let data = try? Data(contentsOf: output) else { return }
        TestHooks.dump("export-\(ReaderController.safeFileName(source.entry.title)).\(output.pathExtension)", data: data)
    }
}
