import PDFKit
import PencilKit
import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: String
    let selection: PDFSelection
}

enum ExportKind {
    case pdfWithDrawings, pdfClean, originalFile, pageImage
}

/// The first responder the tool picker is shown for while drawing.
final class ResponderAnchorView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

/// Owns the PDF view, one PencilKit canvas over each visible page, the tool picker and the
/// per-page drawings of one document.
@MainActor
final class ReaderController: NSObject, ObservableObject {
    let documentID: UUID
    let title: String
    let pdfView = PDFView()
    let thumbnails = PDFThumbnailView()
    let toolPicker = PKToolPicker()

    @Published private(set) var isDrawing = false
    @Published private(set) var currentPage = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isBusy = false
    @Published private(set) var fingerDrawing = AppSettings.fingerDrawing
    @Published private(set) var twoPages = false
    @Published var showThumbnails = false {
        didSet { updateThumbnails() }
    }
    @Published var shareItem: ShareItem?
    @Published var errorText: String?
    @Published var searchResults: [SearchHit] = []

    private(set) var pdfDocument: PDFDocument?
    private let library: DocumentLibrary
    private let store: DrawingStore
    private let anchor = ResponderAnchorView(frame: .zero)
    private var canvases: [Int: PKCanvasView] = [:]
    private weak var lastCanvas: PKCanvasView?
    private var edited = false
    private var container: UIView?
    private var thumbnailsHeight: NSLayoutConstraint?

    init(document: LibraryDocument, library: DocumentLibrary) {
        documentID = document.id
        title = document.title
        self.library = library
        store = DrawingStore(folder: library.drawingsFolder(for: document))
        super.init()
        configure()
        load(url: library.pdfURL(for: document))
    }

    var notes: [String] {
        library.document(with: documentID)?.notes ?? []
    }

    var canRerender: Bool {
        guard let document = library.document(with: documentID) else { return false }
        return document.kind.isConverted && library.originalURL(for: document) != nil
    }

    var hasOriginal: Bool {
        guard let document = library.document(with: documentID) else { return false }
        return library.originalURL(for: document) != nil
    }

    // MARK: Setup

    private func configure() {
        // The overlay provider must be set before the document.
        pdfView.pageOverlayViewProvider = self
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .systemGroupedBackground
        pdfView.autoScales = true
        pdfView.isInMarkupMode = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.accessibilityIdentifier = "pdfView"

        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        thumbnails.layoutMode = .horizontal
        thumbnails.thumbnailSize = CGSize(width: 38, height: 52)
        thumbnails.backgroundColor = .systemGroupedBackground
        thumbnails.pdfView = pdfView

        toolPicker.colorUserInterfaceStyle = .light

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewPageChanged, object: pdfView)
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(undoStateDidChange), name: name, object: nil)
        }
    }

    private func load(url: URL) {
        guard let document = PDFDocument(url: url) else {
            errorText = "Не удалось открыть страницы документа."
            return
        }
        pdfDocument = document
        pdfView.document = document
        pageCount = document.pageCount
        currentPage = 0
        fixScrollInsets()
    }

    /// PDFView's own scroll view adds the navigation bar height on top of the first page
    /// (the view already sits below the bar), which left a wide gray gap above page 1.
    private func fixScrollInsets() {
        func scrollView(in view: UIView) -> UIScrollView? {
            for sub in view.subviews {
                if let scroll = sub as? UIScrollView { return scroll }
                if let found = scrollView(in: sub) { return found }
            }
            return nil
        }
        guard let scroll = scrollView(in: pdfView) else { return }
        scroll.contentInsetAdjustmentBehavior = .never
        if TestHooks.dumpEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                Log.info("reader scroll: offset \(scroll.contentOffset), inset \(scroll.contentInset), adjusted \(scroll.adjustedContentInset), safe area \(self.pdfView.safeAreaInsets), frame \(scroll.frame)")
            }
        }
    }

    func makeContainer() -> UIView {
        if let container { return container }
        let view = UIView()
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(pdfView)
        view.addSubview(thumbnails)
        view.addSubview(anchor)
        let height = thumbnails.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: thumbnails.topAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnails.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            height,
        ])
        thumbnailsHeight = height
        container = view
        updateThumbnails()
        DispatchQueue.main.async { [weak self] in self?.fixScrollInsets() }
        return view
    }

    private func updateThumbnails() {
        thumbnailsHeight?.constant = showThumbnails ? 68 : 0
        thumbnails.isHidden = !showThumbnails
    }

    // MARK: Pages

    @objc private func pageDidChange() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        currentPage = document.index(for: page)
    }

    /// Two pages side by side (the unfolded iPhone Duo, iPad).
    func setTwoPages(_ on: Bool) {
        twoPages = on
        let page = pdfView.currentPage
        // Pages 1 and 2 side by side, as in Word and Preview (no lone cover page), then fit the new
        // width: PDFView keeps the old scale when only the display mode changes.
        pdfView.autoScales = false
        pdfView.displaysAsBook = false
        pdfView.displayMode = on ? .twoUpContinuous : .singlePageContinuous
        pdfView.layoutDocumentView()
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        pdfView.autoScales = true
        fixScrollInsets()
        if let page { pdfView.go(to: page) }
    }

    func goToPage(_ index: Int) {
        guard let document = pdfDocument, document.pageCount > 0,
              let page = document.page(at: max(0, min(index, document.pageCount - 1))) else { return }
        pdfView.go(to: page)
    }

    // MARK: Drawing

    func setDrawing(_ on: Bool) {
        guard on != isDrawing else { return }
        isDrawing = on
        pdfView.isInMarkupMode = on
        for canvas in canvases.values {
            canvas.isUserInteractionEnabled = on
            canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
            toolPicker.setVisible(on, forFirstResponder: canvas)
        }
        toolPicker.setVisible(on, forFirstResponder: anchor)
        if on {
            anchor.becomeFirstResponder()
        } else {
            anchor.resignFirstResponder()
            saveDrawings()
        }
        refreshUndoState()
    }

    func setFingerDrawing(_ on: Bool) {
        fingerDrawing = on
        UserDefaults.standard.set(on, forKey: AppSettings.Key.fingerDrawing)
        for canvas in canvases.values {
            canvas.drawingPolicy = on ? .anyInput : .pencilOnly
        }
    }

    private var activeUndoManager: UndoManager? {
        lastCanvas?.undoManager ?? anchor.undoManager ?? pdfView.undoManager
    }

    func undo() {
        activeUndoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        activeUndoManager?.redo()
        refreshUndoState()
    }

    @objc private func undoStateDidChange(_ notification: Notification) {
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = activeUndoManager?.canUndo ?? false
        canRedo = activeUndoManager?.canRedo ?? false
    }

    func clearCurrentPage() {
        let index = currentPage
        if let canvas = canvases[index] {
            canvas.drawing = PKDrawing()
        }
        store.update(PKDrawing(), canvasSize: canvases[index]?.bounds.size ?? .zero, for: index)
        edited = true
        saveDrawings()
    }

    var currentPageHasDrawing: Bool {
        if let canvas = canvases[currentPage] { return !canvas.drawing.strokes.isEmpty }
        return store.nonEmptyDrawing(for: currentPage) != nil
    }

    func saveDrawings() {
        for canvas in canvases.values {
            store.update(canvas.drawing, canvasSize: canvas.bounds.size, for: canvas.tag)
        }
        store.saveNow()
        if edited {
            edited = false
            library.markEdited(documentID)
        }
    }

    func close() {
        if isDrawing { setDrawing(false) }
        saveDrawings()
    }

    // MARK: Pages added by the person

    func appendBlankPage(style: NotebookStyle) {
        guard let document = pdfDocument, let entry = library.document(with: documentID) else { return }
        let last = document.pageCount > 0 ? document.page(at: document.pageCount - 1) : nil
        let size = last.map { PDFExporter.displayRect(for: $0).size } ?? PaperSize.a4.size
        guard let blank = PDFDocument(data: ImagePDF.blankPage(size: size, style: style))?.page(at: 0) else { return }
        saveDrawings()
        document.insert(blank, at: document.pageCount)
        guard let data = document.dataRepresentation() else {
            errorText = "Не удалось сохранить страницу."
            return
        }
        do {
            try data.write(to: library.pdfURL(for: entry), options: .atomic)
            pageCount = document.pageCount
            library.updatePageCount(documentID, pageCount: pageCount)
            goToPage(pageCount - 1)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func rerender() async {
        guard let entry = library.document(with: documentID), entry.kind.isConverted else { return }
        if isDrawing { setDrawing(false) }
        saveDrawings()
        isBusy = true
        let ok = await library.rerender(entry)
        isBusy = false
        guard ok, let updated = library.document(with: documentID) else { return }
        for canvas in canvases.values { toolPicker.removeObserver(canvas) }
        canvases.removeAll()
        load(url: library.pdfURL(for: updated))
    }

    // MARK: Search

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = pdfDocument, !query.isEmpty else {
            clearSearch()
            return
        }
        let selections = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        pdfView.highlightedSelections = selections
        searchResults = selections.prefix(300).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let around = (selection.copy() as? PDFSelection) ?? selection
            around.extend(atStart: 30)
            around.extend(atEnd: 30)
            let snippet = (around.string ?? query)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return SearchHit(pageIndex: document.index(for: page), snippet: snippet, selection: selection)
        }
    }

    func show(_ hit: SearchHit) {
        pdfView.go(to: hit.selection)
        pdfView.setCurrentSelection(hit.selection, animate: true)
    }

    func clearSearch() {
        searchResults = []
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    // MARK: Export, print

    func export(_ kind: ExportKind) {
        guard let document = pdfDocument, let entry = library.document(with: documentID) else { return }
        saveDrawings()
        let fm = FileManager.default
        do {
            let folder = fm.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = Self.safeFileName(title)
            let url: URL
            switch kind {
            case .pdfWithDrawings:
                let data = PDFExporter.flattenedPDF(document, drawings: store.allDrawings, canvasSizes: store.allCanvasSizes)
                url = folder.appendingPathComponent(base + ".pdf")
                try data.write(to: url)
                TestHooks.dump("export-\(entry.kind.rawValue).pdf", data: data)
            case .pdfClean:
                url = folder.appendingPathComponent(base + ".pdf")
                try fm.copyItem(at: library.pdfURL(for: entry), to: url)
            case .originalFile:
                guard let original = library.originalURL(for: entry) else {
                    errorText = "У этого документа нет исходного файла."
                    return
                }
                let name = entry.originalFileName.isEmpty ? base + "." + original.pathExtension : entry.originalFileName
                url = folder.appendingPathComponent(name)
                try fm.copyItem(at: original, to: url)
            case .pageImage:
                guard let page = document.page(at: currentPage) else { return }
                let image = PDFExporter.pageImage(page, drawing: store.nonEmptyDrawing(for: currentPage),
                                                  canvasSize: store.canvasSize(for: currentPage))
                url = folder.appendingPathComponent("\(base), стр. \(currentPage + 1).png")
                guard let png = image.pngData() else { return }
                try png.write(to: url)
            }
            shareItem = ShareItem(urls: [url])
            presentShare([url])
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// The system share sheet, shown in the window this document is in.
    private func presentShare(_ urls: [URL]) {
        guard let root = pdfView.window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.maxX - 60, y: top.view.safeAreaInsets.top + 8, width: 1, height: 1)
            popover.permittedArrowDirections = [.up]
        }
        top.present(sheet, animated: true)
    }

    func printDocument() {
        guard let document = pdfDocument else { return }
        saveDrawings()
        let data = PDFExporter.flattenedPDF(document, drawings: store.allDrawings, canvasSizes: store.allCanvasSizes)
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true, completionHandler: nil)
    }

    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Документ" : String(cleaned.prefix(120))
    }
}

// MARK: - Canvases over pages

extension ReaderController: PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        if let existing = canvases[index] { return existing }
        let canvas = PKCanvasView(frame: .zero)
        canvas.tag = index
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Ink colours must not flip in dark mode: the page is always white.
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvas.drawing = store.drawing(for: index)
        canvas.tool = toolPicker.selectedTool
        canvas.isUserInteractionEnabled = isDrawing
        canvas.accessibilityIdentifier = "canvas-\(index)"
        canvas.delegate = self
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(isDrawing, forFirstResponder: canvas)
        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        store.update(canvas.drawing, canvasSize: canvas.bounds.size, for: canvas.tag)
        toolPicker.removeObserver(canvas)
        if canvases[canvas.tag] === canvas {
            canvases[canvas.tag] = nil
        }
    }
}

extension ReaderController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        store.update(canvasView.drawing, canvasSize: canvasView.bounds.size, for: canvasView.tag)
        lastCanvas = canvasView
        edited = true
        refreshUndoState()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        lastCanvas = canvasView
    }
}

struct PDFReaderView: UIViewRepresentable {
    let controller: ReaderController

    func makeUIView(context: Context) -> UIView {
        controller.makeContainer()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
