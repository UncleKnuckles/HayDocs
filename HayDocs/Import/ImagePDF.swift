import UIKit

enum NotebookStyle: String, CaseIterable, Identifiable {
    case blank, lined, grid, dots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Чистые"
        case .lined: return "В линейку"
        case .grid: return "В клетку"
        case .dots: return "В точку"
        }
    }
}

/// PDFs made from pictures (photos, scans) and empty notebook pages.
enum ImagePDF {
    /// One picture per page, page width A4 (595 pt), height by the picture's shape.
    static func make(from images: [UIImage], pageWidth: CGFloat = 595.28) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: 841.89))
        return renderer.pdfData { context in
            for original in images {
                let image = prepared(original)
                let size = image.size
                guard size.width > 0, size.height > 0 else { continue }
                let height = (pageWidth * size.height / size.width).rounded()
                let rect = CGRect(x: 0, y: 0, width: pageWidth, height: max(height, 1))
                context.beginPage(withBounds: rect, pageInfo: [:])
                image.draw(in: rect)
            }
        }
    }

    /// Big camera pictures are scaled to at most 2400 px and stored as JPEG, so a page
    /// stays a few hundred KB instead of tens of MB.
    private static func prepared(_ image: UIImage) -> UIImage {
        let maxSide: CGFloat = 2400
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let factor = min(1, maxSide / max(pixelWidth, pixelHeight))
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let jpeg = redrawn.jpegData(compressionQuality: 0.85), let decoded = UIImage(data: jpeg) {
            return decoded
        }
        return redrawn
    }

    static func notebook(pages: Int, size: CGSize, style: NotebookStyle) -> Data {
        let rect = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: rect)
        return renderer.pdfData { context in
            for _ in 0..<max(1, pages) {
                context.beginPage()
                drawPaper(style, in: rect, context: context.cgContext)
            }
        }
    }

    static func blankPage(size: CGSize, style: NotebookStyle = .blank) -> Data {
        notebook(pages: 1, size: size, style: style)
    }

    private static func drawPaper(_ style: NotebookStyle, in rect: CGRect, context: CGContext) {
        UIColor.white.setFill()
        context.fill(rect)
        let step: CGFloat = 22.7 // 8 mm
        let margin: CGFloat = 42
        let line = UIColor(red: 0.62, green: 0.71, blue: 0.86, alpha: 0.7)
        switch style {
        case .blank:
            break
        case .lined:
            context.setStrokeColor(line.cgColor)
            context.setLineWidth(0.6)
            var y = margin + step
            while y < rect.height - margin / 2 {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: rect.width, y: y))
                y += step
            }
            context.strokePath()
        case .grid:
            let cell: CGFloat = 14.17 // 5 mm
            context.setStrokeColor(line.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(0.4)
            var x: CGFloat = 0
            while x <= rect.width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: rect.height))
                x += cell
            }
            var y: CGFloat = 0
            while y <= rect.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: rect.width, y: y))
                y += cell
            }
            context.strokePath()
        case .dots:
            let cell: CGFloat = 14.17
            context.setFillColor(line.cgColor)
            var y = cell
            while y < rect.height {
                var x = cell
                while x < rect.width {
                    context.fillEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
                    x += cell
                }
                y += cell
            }
        }
    }
}
