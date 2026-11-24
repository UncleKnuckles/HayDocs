import Foundation
import PDFKit
import UIKit

struct ConversionResult {
    let pdfData: Data
    let notes: [String]
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

    private static func convertWithEngine(_ url: URL, kind: DocumentKind) async throws -> ConversionResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Convert-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var notes: [String] = []
        var input = url
        let ext = url.pathExtension.lowercased()
        if kind == .text {
            // Any text file: decoded here (old Armenian and Russian encodings too), handed over as UTF-8.
            let decoded = TextDecoder.decode(try Data(contentsOf: url), armscii: AppSettings.armsciiConversion)
            if decoded.encodingName == "ArmSCII-8" {
                notes.append("Текст в кодировке ArmSCII-8 переведён в Юникод.")
            }
            let isMarkdown = ext == "md" || ext == "markdown"
            input = work.appendingPathComponent(isMarkdown ? "text.md" : "text.txt")
            try decoded.text.write(to: input, atomically: true, encoding: .utf8)
        } else if !engineExtensions.contains(ext) {
            let name = kind == .html ? "page.html" : "document.\(ext)"
            input = work.appendingPathComponent(name)
            try fm.copyItem(at: url, to: input)
        }

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
        return ConversionResult(pdfData: data, notes: notes + report.notes)
    }
}
