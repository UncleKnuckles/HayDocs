import PDFKit
import PencilKit
import UIKit

/// The Pencil drawings as the document engine puts them on pages: each stroke as points on its
/// page (page points from the top left corner), with its tool, colour, opacity and width.
enum InkStrokes {
    static func strokes(of drawing: PKDrawing, page: Int, canvasSize: CGSize, pageSize: CGSize) -> [[String: Any]] {
        // The canvas lies over the whole page: its points scale to page points.
        let sx = pageSize.width / max(canvasSize.width, 1)
        let sy = pageSize.height / max(canvasSize.height, 1)
        var out: [[String: Any]] = []
        for stroke in drawing.strokes {
            let tool = toolName(stroke.ink.inkType)
            let (color, colorAlpha) = hexColor(stroke.ink.color)
            let transform = stroke.transform
            let transformScale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            let last = CGFloat(max(stroke.path.count - 1, 0))
            // What the pixel eraser left of the stroke.
            let ranges = stroke.mask == nil ? [0...last] : stroke.maskedPathRanges
            for range in ranges {
                var points: [CGPoint] = []
                var widths: CGFloat = 0
                var opacities: CGFloat = 0
                for point in stroke.path.interpolatedPoints(in: range, by: .distance(1)) {
                    let p = point.location.applying(transform)
                    points.append(CGPoint(x: p.x * sx, y: p.y * sy))
                    widths += point.size.width
                    opacities += point.opacity
                }
                guard !points.isEmpty else { continue }
                let n = CGFloat(points.count)
                let width = widths / n * transformScale * (sx + sy) / 2
                let alpha = tool == "highlighter" ? 0.5 : min(1, max(0.05, colorAlpha * opacities / n))
                out.append([
                    "page": page,
                    "tool": tool,
                    "color": color,
                    "alpha": Double(alpha),
                    "width": Double(width),
                    "points": simplify(points, tolerance: 0.12).map { [Double($0.x), Double($0.y)] },
                ])
            }
        }
        return out
    }

    /// The engine's three tools: pens, pencils and markers.
    private static func toolName(_ type: PKInk.InkType) -> String {
        switch type {
        case .marker, .watercolor: return "highlighter"
        case .pencil, .crayon: return "pencil"
        default: return "pen"
        }
    }

    /// "RRGGBB" in sRGB, as the ink shows on the light canvas, and its opacity.
    private static func hexColor(_ color: UIColor) -> (String, CGFloat) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if resolved.getWhite(&white, alpha: &a) { (r, g, b) = (white, white, white) }
        }
        let byte = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
        return (String(format: "%02lX%02lX%02lX", byte(r), byte(g), byte(b)), min(1, max(0, a)))
    }

    /// Fewer points along the same line (Ramer–Douglas–Peucker): none moves more than `tolerance`.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(sqrt(dx * dx + dy * dy), 1e-6)
            var farthest = first
            var distance: CGFloat = 0
            for i in (first + 1)..<last {
                let p = points[i]
                let d = abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / length
                if d > distance {
                    distance = d
                    farthest = i
                }
            }
            if distance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
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
/// stays text and each stroke becomes ink on its page that Word and LibreOffice can move or delete.
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
        _ = try await WordEngine.shared.export(input: nil, output: output, strokes: [], pictures: pictures, title: title)
        dumpForTests(output, source: source)
        return output
    }

    /// The original laid out again with the strokes on pages before `own`, and the pages from
    /// `own` on (added in the app) as pictures after its text.
    private static func withText(input: URL, own: Int, output: URL, source: Source, work: URL, title: String,
                                 progress: @escaping (String) -> Void) async throws -> WordEngine.ExportAnswer {
        var strokes: [[String: Any]] = []
        for index in source.drawings.keys.sorted() where index < own {
            guard let drawing = source.drawings[index], let page = source.pdf.page(at: index) else { continue }
            let size = PDFExporter.displayRect(for: page).size
            strokes += InkStrokes.strokes(of: drawing, page: index, canvasSize: source.canvasSizes[index] ?? size, pageSize: size)
        }
        let pictures = try await renderPictures(of: own..<source.pdf.pageCount, source: source, work: work, progress: progress)
        progress("Сохраняю…")
        return try await WordEngine.shared.export(input: input, output: output, strokes: strokes, pictures: pictures, title: title)
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
