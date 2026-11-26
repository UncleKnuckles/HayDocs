import Foundation
import PDFKit
import UIKit

struct ConversionResult {
    let pdfData: Data
    let notes: [String]
    /// The document engine made the pages.
    var byEngine = false
}

enum ConversionError: LocalizedError {
    case unreadable
    case lockedPDF
    case unsupported(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Файл повреждён или это не документ."
        case .lockedPDF: return "Этот PDF защищён паролем. Снимите пароль и откройте файл снова."
        case .unsupported(let ext): return "Формат «.\(ext)» пока не поддерживается."
        case .empty: return "В документе нет страниц."
        }
    }
}

/// Every document is shown as PDF pages: PDFs as they are, pictures one per page, Word, ODT, RTF,
/// HTML and text through the document engine, spreadsheets and slides through the system viewer.
enum DocumentConverter {
    /// Extensions the engine opens itself.
    private static let engineExtensions: Set<String> = [
        "docx", "docm", "dotx", "dotm", "doc", "dot", "odt", "ott", "fodt", "rtf", "html", "htm", "md", "markdown", "txt", "xml",
    ]

    static func convert(fileAt url: URL, kind: DocumentKind) async throws -> ConversionResult {
        switch kind {
        case .pdf:
            let data = try Data(contentsOf: url)
            guard let document = PDFDocument(data: data) else { throw ConversionError.unreadable }
            if document.isLocked { throw ConversionError.lockedPDF }
            guard document.pageCount > 0 else { throw ConversionError.empty }
            return ConversionResult(pdfData: data, notes: [])

        case .image:
            guard let image = UIImage(contentsOfFile: url.path) else { throw ConversionError.unreadable }
            return ConversionResult(pdfData: ImagePDF.make(from: [image]), notes: [])

        case .word, .odt, .rtf, .text, .html:
            do {
                return try await convertWithEngine(url, kind: kind)
            } catch let error as EngineError where kind == .word || kind == .rtf || kind == .html {
                // The system viewer reads some files the engine can't (for example very old Word).
                Log.info("engine failed (\(error.localizedDescription)), trying the system viewer")
                if case .needsPassword = error { throw error }
                let data = try await WebDocumentRenderer.render(fileAt: url, paper: AppSettings.paper)
                return ConversionResult(pdfData: data, notes: ["Показано системным просмотрщиком: \(error.localizedDescription)"])
            }

        case .spreadsheet, .presentation:
            let data = try await WebDocumentRenderer.render(fileAt: url, paper: AppSettings.paper)
            return ConversionResult(pdfData: data, notes: ["Таблицы и слайды показаны системным просмотрщиком, без правки шрифтов."])

        case .scan, .notebook:
            throw ConversionError.unsupported(url.pathExtension)
        }
    }

    /// The file to hand the engine for `url`, in `work`: text decoded to UTF-8 (old Armenian
    /// and Russian encodings too), other files under a name whose extension the engine reads.
    /// Returns it and a note when the text was in ArmSCII-8.
    static func engineInput(for url: URL, kind: DocumentKind, in work: URL) throws -> (url: URL, note: String?) {
        let ext = url.pathExtension.lowercased()
        if kind == .text {
            let decoded = TextDecoder.decode(try Data(contentsOf: url), armscii: AppSettings.armsciiConversion)
            let note = decoded.encodingName == "ArmSCII-8" ? "Текст в кодировке ArmSCII-8 переведён в Юникод." : nil
            let isMarkdown = ext == "md" || ext == "markdown"
            let input = work.appendingPathComponent(isMarkdown ? "text.md" : "text.txt")
            try decoded.text.write(to: input, atomically: true, encoding: .utf8)
            return (input, note)
        }
        if !engineExtensions.contains(ext) {
            let input = work.appendingPathComponent(kind == .html ? "page.html" : "document.\(ext)")
            try FileManager.default.copyItem(at: url, to: input)
            return (input, nil)
        }
        return (url, nil)
    }

    private static func convertWithEngine(_ url: URL, kind: DocumentKind) async throws -> ConversionResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Convert-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (input, note) = try engineInput(for: url, kind: kind, in: work)
        let notes = note.map { [$0] } ?? []

        let output = work.appendingPathComponent("document.pdf")
        var report = try await WordEngine.shared.convert(WordEngine.Request(input: input, output: output))
        if kind == .text {
            // A plain text file names no fonts: the engine's default font missing is not the user's concern.
            report.missingFonts = []
        }
        let data = try Data(contentsOf: output)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ConversionError.empty }
        if TestHooks.dumpEnabled {
            let name = "engine-\(url.deletingLastPathComponent().lastPathComponent.prefix(8))-\(url.lastPathComponent).pdf"
            TestHooks.dump(name, data: data)
            Log.info("engine dump \(name)")
        }
        return ConversionResult(pdfData: data, notes: notes + report.notes, byEngine: true)
    }
}
