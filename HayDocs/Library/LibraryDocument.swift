import Foundation
import UniformTypeIdentifiers

enum DocumentKind: String, Codable, CaseIterable {
    case pdf, word, odt, rtf, text, html, spreadsheet, presentation, image, scan, notebook

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .word: return "Word"
        case .odt: return "ODT"
        case .rtf: return "RTF"
        case .text: return "TXT"
        case .html: return "HTML"
        case .spreadsheet: return "Таблица"
        case .presentation: return "Слайды"
        case .image: return "Фото"
        case .scan: return "Скан"
        case .notebook: return "Блокнот"
        }
    }

    /// Kinds whose pages are made from the original file (and can be made again).
    var isConverted: Bool {
        switch self {
        case .word, .odt, .rtf, .text, .html, .spreadsheet, .presentation: return true
        case .pdf, .image, .scan, .notebook: return false
        }
    }

    static func detect(fileExtension ext: String) -> DocumentKind? {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "doc", "docx", "docm", "dot", "dotx", "dotm": return .word
        case "odt", "ott", "fodt": return .odt
        case "rtf": return .rtf
        case "txt", "text", "md", "markdown", "csv", "log": return .text
        case "htm", "html", "xhtml": return .html
        case "xls", "xlsx", "xlsm": return .spreadsheet
        case "ppt", "pptx", "pps", "ppsx": return .presentation
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tif", "tiff", "webp":
            return .image
        default: return nil
        }
    }
}

struct LibraryDocument: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    /// File name the document came in with ("Отчёт.docx"); empty for scans and notebooks.
    var originalFileName: String
    var kind: DocumentKind
    var created: Date
    var modified: Date
    var pageCount: Int
    /// What was done to show it (e.g. old Armenian encoding converted), shown in the reader menu.
    var notes: [String] = []

    var originalExtension: String {
        (originalFileName as NSString).pathExtension.lowercased()
    }
}

/// Types offered in the file picker. `.item` keeps every file selectable: the extension decides.
enum ImportTypes {
    static var documents: [UTType] {
        var types: [UTType] = [.pdf, .rtf, .plainText, .html, .image, .font]
        let identifiers = [
            "org.openxmlformats.wordprocessingml.document",
            "com.microsoft.word.doc",
            "org.oasis-open.opendocument.text",
            "org.openxmlformats.spreadsheetml.sheet",
            "com.microsoft.excel.xls",
            "org.openxmlformats.presentationml.presentation",
            "com.microsoft.powerpoint.ppt",
        ]
        for identifier in identifiers {
            if let type = UTType(identifier) { types.append(type) }
        }
        if let odt = UTType(filenameExtension: "odt") { types.append(odt) }
        types.append(.item)
        return types
    }

    static var fonts: [UTType] {
        var types: [UTType] = [.font]
        for ext in ["ttf", "otf", "ttc", "otc", "woff", "woff2"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.item)
        return types
    }
}
