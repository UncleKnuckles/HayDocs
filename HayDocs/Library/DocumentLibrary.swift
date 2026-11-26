import Foundation
import PDFKit
import PencilKit
import SwiftUI
import UIKit

struct ImportJob: Identifiable, Equatable {
    let id = UUID()
    let name: String
}

struct LibraryMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// Every document lives in its own folder:
///   Application Support/HayDocs/Library/<id>/
///     info.json        metadata
///     document.pdf     the pages shown and drawn on
///     original.<ext>   the file as imported (Word, ODT…), kept to re-render or export
///     drawings/        one PencilKit drawing per page
///     thumbnail.jpg
@MainActor
final class DocumentLibrary: ObservableObject {
    static let shared = DocumentLibrary()

    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var activeImports: [ImportJob] = []
    @Published var message: LibraryMessage?
    /// Bumped when a thumbnail changes, so cards reload their picture.
    @Published private(set) var thumbnailRevision = 0

    nonisolated static var libraryRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HayDocs/Library", isDirectory: true)
    }

    private let fm = FileManager.default
    private var isImportingFolder = false

    init() {
        try? fm.createDirectory(at: Self.libraryRoot, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Paths

    func folder(for id: UUID) -> URL {
        Self.libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func pdfURL(for document: LibraryDocument) -> URL {
        folder(for: document.id).appendingPathComponent("document.pdf")
    }

    func originalURL(for document: LibraryDocument) -> URL? {
        guard !document.originalFileName.isEmpty else { return nil }
        let ext = document.originalExtension.isEmpty ? "bin" : document.originalExtension
        let url = folder(for: document.id).appendingPathComponent("original.\(ext)")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func drawingsFolder(for document: LibraryDocument) -> URL {
        folder(for: document.id).appendingPathComponent("drawings", isDirectory: true)
    }

    func thumbnailURL(for document: LibraryDocument) -> URL {
        folder(for: document.id).appendingPathComponent("thumbnail.jpg")
    }

    private func infoURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("info.json")
    }

    // MARK: Metadata

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [LibraryDocument] = []
        let folders = (try? fm.contentsOfDirectory(at: Self.libraryRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let info = folder.appendingPathComponent("info.json")
            guard let data = try? Data(contentsOf: info),
                  let document = try? decoder.decode(LibraryDocument.self, from: data) else { continue }
            found.append(document)
        }
        documents = found.sorted { $0.modified > $1.modified }
    }

    func document(with id: UUID) -> LibraryDocument? {
        documents.first { $0.id == id }
    }

    func save(_ document: LibraryDocument) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(document) {
            try? data.write(to: infoURL(for: document.id), options: .atomic)
        }
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.append(document)
        }
        documents.sort { $0.modified > $1.modified }
    }

    /// Called when drawings change: moves the document to the top and refreshes its picture.
    func markEdited(_ id: UUID) {
        guard var document = document(with: id) else { return }
        document.modified = Date()
        save(document)
        makeThumbnail(for: document)
    }

    /// A page was added in the app: before the first one, the pages so far are the file's own.
    func updatePageCount(_ id: UUID, pageCount: Int, sourcePages: Int? = nil) {
        guard var document = document(with: id) else { return }
        if document.sourcePages == nil, let sourcePages { document.sourcePages = sourcePages }
        document.pageCount = pageCount
        document.modified = Date()
        save(document)
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                await importFile(at: url)
            }
        }
    }

    @discardableResult
    func importFile(at url: URL, title: String? = nil) async -> LibraryDocument? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        if FontLibrary.fontExtensions.contains(ext) {
            do {
                let faces = try FontLibrary.shared.importFont(from: url)
                let families = Array(Set(faces.map(\.family))).sorted().joined(separator: ", ")
                message = LibraryMessage(title: "Шрифт добавлен", text: families.isEmpty ? url.lastPathComponent : families)
            } catch {
                message = LibraryMessage(title: "Шрифт не добавлен", text: error.localizedDescription)
            }
            return nil
        }

        guard let kind = DocumentKind.detect(fileExtension: ext) else {
            message = LibraryMessage(title: "Не удалось открыть",
                                     text: "Формат «.\(ext)» пока не поддерживается: \(url.lastPathComponent)")
            return nil
        }

        let job = ImportJob(name: url.lastPathComponent)
        activeImports.append(job)
        defer { activeImports.removeAll { $0 == job } }

        let id = UUID()
        let folder = folder(for: id)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = folder.appendingPathComponent("original.\(ext.isEmpty ? "bin" : ext)")
            try copyCoordinated(from: url, to: original)

            Log.info("import \(url.lastPathComponent) as \(kind.rawValue)")
            let result = try await DocumentConverter.convert(fileAt: original, kind: kind)
            let pdfURL = folder.appendingPathComponent("document.pdf")
            try result.pdfData.write(to: pdfURL, options: .atomic)
            if kind == .pdf || kind == .image {
                // The PDF itself is the document; a photo keeps no second copy either.
                try? fm.removeItem(at: original)
            }
            let pageCount = PDFDocument(url: pdfURL)?.pageCount ?? 0
            let now = Date()
            let document = LibraryDocument(
                id: id,
                title: title ?? url.deletingPathExtension().lastPathComponent,
                originalFileName: kind == .pdf || kind == .image ? "" : url.lastPathComponent,
                kind: kind,
                created: now,
                modified: now,
                pageCount: pageCount,
                notes: result.notes,
                sourcePages: pageCount,
                madeByEngine: result.byEngine
            )
            save(document)
            makeThumbnail(for: document)
            Log.info("imported \(document.title): \(pageCount) pages, notes: \(result.notes)")
            return document
        } catch {
            try? fm.removeItem(at: folder)
            Log.info("import failed \(url.lastPathComponent): \(error)")
            message = LibraryMessage(title: "Не удалось открыть «\(url.lastPathComponent)»",
                                     text: error.localizedDescription)
            return nil
        }
    }

    /// Photos and scans: one picture per page.
    func importImages(_ images: [UIImage], title: String, kind: DocumentKind) async {
        guard !images.isEmpty else { return }
        let job = ImportJob(name: title)
        activeImports.append(job)
        defer { activeImports.removeAll { $0 == job } }
        await Task.yield()
        let data = ImagePDF.make(from: images)
        createDocument(pdfData: data, title: title, kind: kind)
    }

    func createNotebook(pages: Int, style: NotebookStyle, paper: PaperSize) {
        let data = ImagePDF.notebook(pages: pages, size: paper.size, style: style)
        createDocument(pdfData: data, title: "Блокнот \(Self.shortDate.string(from: Date()))", kind: .notebook)
    }

    @discardableResult
    private func createDocument(pdfData: Data, title: String, kind: DocumentKind) -> LibraryDocument? {
        let id = UUID()
        let folder = folder(for: id)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let pdfURL = folder.appendingPathComponent("document.pdf")
            try pdfData.write(to: pdfURL, options: .atomic)
            let now = Date()
            let pages = PDFDocument(url: pdfURL)?.pageCount ?? 0
            let document = LibraryDocument(id: id, title: title, originalFileName: "", kind: kind,
                                           created: now, modified: now,
                                           pageCount: pages, sourcePages: pages, madeByEngine: false)
            save(document)
            makeThumbnail(for: document)
            return document
        } catch {
            try? fm.removeItem(at: folder)
            message = LibraryMessage(title: "Не удалось создать документ", text: error.localizedDescription)
            return nil
        }
    }

    /// The sample documents shipped with the app (Armenian text in every format).
    func addSamples() async {
        guard let folder = Bundle.main.url(forResource: "Samples", withExtension: nil) else { return }
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files {
            await importFile(at: file)
        }
    }

    /// Files put into the app's folder ("On My iPhone › HayDocs" in the Files app, or copied from a
    /// computer) and files other apps hand over (Documents/Inbox) are imported, then moved to
    /// "Импортированные" so they are not imported twice.
    func importFromAppFolder() {
        guard !isImportingFolder else { return }
        let documentsFolder = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = documentsFolder.appendingPathComponent("Inbox", isDirectory: true)
        let done = documentsFolder.appendingPathComponent("Импортированные", isDirectory: true)
        var candidates: [URL] = []
        for folder in [documentsFolder, inbox] {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            for item in items {
                let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile, !item.lastPathComponent.hasPrefix(".") else { continue }
                let ext = item.pathExtension.lowercased()
                if DocumentKind.detect(fileExtension: ext) != nil || FontLibrary.fontExtensions.contains(ext) {
                    candidates.append(item)
                }
            }
        }
        guard !candidates.isEmpty else { return }
        isImportingFolder = true
        Task { @MainActor in
            defer { isImportingFolder = false }
            try? fm.createDirectory(at: done, withIntermediateDirectories: true)
            for file in candidates {
                _ = await importFile(at: file)
                var target = done.appendingPathComponent(file.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    let base = file.deletingPathExtension().lastPathComponent
                    target = done.appendingPathComponent("\(base) \(n).\(file.pathExtension)")
                    n += 1
                }
                try? fm.moveItem(at: file, to: target)
            }
        }
    }

    private func copyCoordinated(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    // MARK: Editing

    func rename(_ document: LibraryDocument, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var updated = self.document(with: document.id) else { return }
        updated.title = trimmed
        save(updated)
    }

    func duplicate(_ document: LibraryDocument) {
        let id = UUID()
        do {
            try fm.copyItem(at: folder(for: document.id), to: folder(for: id))
            var copy = document
            copy.id = id
            copy.title = document.title + " (копия)"
            copy.created = Date()
            copy.modified = Date()
            save(copy)
            thumbnailRevision += 1
        } catch {
            message = LibraryMessage(title: "Не удалось скопировать", text: error.localizedDescription)
        }
    }

    func delete(_ document: LibraryDocument) {
        try? fm.removeItem(at: folder(for: document.id))
        documents.removeAll { $0.id == document.id }
    }

    /// Make the pages again from the original file (after adding fonts or changing settings).
    /// Drawings stay with their page numbers.
    func rerender(_ document: LibraryDocument) async -> Bool {
        guard document.kind.isConverted, let original = originalURL(for: document) else { return false }
        let job = ImportJob(name: document.title)
        activeImports.append(job)
        defer { activeImports.removeAll { $0 == job } }
        do {
            let result = try await DocumentConverter.convert(fileAt: original, kind: document.kind)
            try result.pdfData.write(to: pdfURL(for: document), options: .atomic)
            var updated = self.document(with: document.id) ?? document
            updated.pageCount = PDFDocument(url: pdfURL(for: document))?.pageCount ?? updated.pageCount
            updated.sourcePages = updated.pageCount
            updated.madeByEngine = result.byEngine
            updated.notes = result.notes
            updated.modified = Date()
            save(updated)
            makeThumbnail(for: updated)
            return true
        } catch {
            message = LibraryMessage(title: "Не удалось перерисовать", text: error.localizedDescription)
            return false
        }
    }

    // MARK: Thumbnails

    func makeThumbnail(for document: LibraryDocument) {
        guard let pdf = PDFDocument(url: pdfURL(for: document)), let page = pdf.page(at: 0) else { return }
        var image = page.thumbnail(of: CGSize(width: 420, height: 594), for: .cropBox)
        let store = DrawingStore(folder: drawingsFolder(for: document))
        if let drawing = store.nonEmptyDrawing(for: 0) {
            let pageSize = PDFExporter.displayRect(for: page).size
            let canvasSize = store.canvasSize(for: 0) ?? pageSize
            let ink = PDFExporter.renderDrawing(drawing, canvasSize: canvasSize, scale: 1)
            let base = image
            let renderer = UIGraphicsImageRenderer(size: base.size)
            image = renderer.image { _ in
                base.draw(at: .zero)
                ink.draw(in: CGRect(origin: .zero, size: base.size))
            }
        }
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: thumbnailURL(for: document), options: .atomic)
        }
        thumbnailRevision += 1
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM HH:mm"
        return f
    }()
}
