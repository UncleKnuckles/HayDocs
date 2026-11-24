import PDFKit
import PencilKit
import UIKit

/// Builds PDFs with the Pencil drawings burned into the pages, and page pictures.
enum PDFExporter {
    /// The page as it is shown: crop box, turned by the page's rotation.
    static func displayRect(for page: PDFPage) -> CGRect {
        let box = page.bounds(for: .cropBox)
        let turned = abs(page.rotation) % 180 == 90
        return CGRect(x: 0, y: 0,
                      width: turned ? box.height : box.width,
                      height: turned ? box.width : box.height)
    }

    /// Draws the page's content (vector, text stays text) into a UIKit-oriented context.
    static func drawPage(_ page: PDFPage, in rect: CGRect, context: CGContext) {
        guard let ref = page.pageRef else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let target = CGRect(origin: .zero, size: rect.size)
        context.concatenate(ref.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
        context.restoreGState()
    }

    /// The drawing as a picture, always in light colours (black ink stays black in dark mode).
    static func renderDrawing(_ drawing: PKDrawing, canvasSize: CGSize, scale: CGFloat) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
        }
        return image
    }

    @MainActor
    static func flattenedPDF(_ document: PDFDocument, drawings: [Int: PKDrawing], canvasSizes: [Int: CGSize]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
        return renderer.pdfData { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let rect = displayRect(for: page)
                context.beginPage(withBounds: rect, pageInfo: [:])
                drawPage(page, in: rect, context: context.cgContext)
                if let drawing = drawings[index], !drawing.strokes.isEmpty {
                    let canvas = canvasSizes[index] ?? rect.size
                    // 3x the page's points: about 216 dpi, sharp enough to print.
                    let ink = renderDrawing(drawing, canvasSize: canvas, scale: 3)
                    ink.draw(in: rect)
                }
            }
        }
    }

    /// One page with its drawing as a PNG picture.
    @MainActor
    static func pageImage(_ page: PDFPage, drawing: PKDrawing?, canvasSize: CGSize?, scale: CGFloat = 3) -> UIImage {
        let rect = displayRect(for: page)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(rect)
            drawPage(page, in: rect, context: context.cgContext)
            if let drawing, !drawing.strokes.isEmpty {
                renderDrawing(drawing, canvasSize: canvasSize ?? rect.size, scale: scale).draw(in: rect)
            }
        }
    }
}
