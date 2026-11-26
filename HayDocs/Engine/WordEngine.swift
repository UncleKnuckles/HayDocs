import Foundation

/// What the engine did besides making pages, in words for the reader's info menu.
struct EngineReport {
    var armsciiRuns = 0
    var fallbackRuns = 0
    var missingFonts: [String] = []
    var legacyFonts: [String] = []

    var notes: [String] {
        var notes: [String] = []
        if armsciiRuns > 0 {
            let fonts = legacyFonts.isEmpty ? "" : " (\(legacyFonts.joined(separator: ", ")))"
            notes.append("Текст в старой кодировке ArmSCII\(fonts) переведён в Юникод.")
        }
        if !missingFonts.isEmpty {
            notes.append("Нет шрифтов: \(missingFonts.joined(separator: ", ")). Армянский текст показан заменой; добавьте эти шрифты в «Шрифты» и выберите «Перерисовать».")
        }
        return notes
    }
}

enum EngineError: LocalizedError {
    case failed(String)
    case needsPassword
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .failed(let text): return "Не удалось прочитать документ: \(text)"
        case .needsPassword: return "Документ защищён паролем."
        case .wrongPassword: return "Неверный пароль."
        }
    }
}

/// The document engine (WordCraft, linked as a static library): Word, ODT, RTF, HTML, Markdown
/// and text files become PDF. Calls run one at a time on a background queue.
final class WordEngine: @unchecked Sendable {
    static let shared = WordEngine()

    private let queue = DispatchQueue(label: "haydocs.engine", qos: .userInitiated)
    private var addedFonts: Set<String> = []

    var version: String {
        String(cString: hd_version())
    }

    /// Hand font files to the engine (each file once).
    func addFonts(_ urls: [URL]) {
        queue.async { [self] in
            let paths = urls.map(\.path).filter { !addedFonts.contains($0) }
            guard !paths.isEmpty,
                  let json = try? JSONSerialization.data(withJSONObject: paths),
                  let text = String(data: json, encoding: .utf8) else { return }
            let added = hd_add_fonts(text)
            addedFonts.formUnion(paths)
            Log.info("engine fonts: \(paths.count) files, \(added) faces")
        }
    }

    struct Request {
        var input: URL
        var output: URL
        var armscii = AppSettings.armsciiConversion
        var serif = AppSettings.serifFallback
        var sans = AppSettings.sansFallback
        var mono = AppSettings.monoFallback
        var paper = AppSettings.paper
        var password: String?
    }

    func convert(_ request: Request) async throws -> EngineReport {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.convertNow(request) })
            }
        }
    }

    /// The options both calls take: the Armenian fixes and the paper.
    private func options(_ request: Request) -> [String: Any] {
        var body: [String: Any] = [
            "input": request.input.path,
            "output": request.output.path,
            "armscii": request.armscii,
            "armenianFallback": true,
            "serif": request.serif,
            "sans": request.sans,
            "mono": request.mono,
            "region": request.paper == .letter ? "en-US" : "hy-AM",
        ]
        if let password = request.password { body["password"] = password }
        return body
    }

    /// What `export` did.
    struct ExportAnswer {
        /// Pages of the original as the engine laid it out (0 without an original).
        var pages = 0
        /// Drawings put in the text, and of them those placed on their page by its corner.
        var drawings = 0
        var onPages = 0
        /// Pages whose drawing could not be put on the page.
        var skippedPages: [Int] = []
    }

    /// Save as Word (.docx) or ODT, the extension of `output` says which. `input` is the
    /// original file, or nil for a document made only of `pictures` (whole pages, each
    /// ["path", "width", "height"]). `drawings` are pictures of the Pencil drawing on the
    /// original's pages, each ["page", "x", "y", "width", "height", "path", "behind"] in page
    /// points from the page's top left corner: the engine ties each to the text under it.
    func export(input: URL?, output: URL, drawings: [[String: Any]], pictures: [[String: Any]], title: String) async throws -> ExportAnswer {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.exportNow(input: input, output: output, drawings: drawings, pictures: pictures, title: title)
                })
            }
        }
    }

    private func exportNow(input: URL?, output: URL, drawings: [[String: Any]], pictures: [[String: Any]], title: String) throws -> ExportAnswer {
        var body = options(Request(input: input ?? output, output: output))
        if input == nil { body.removeValue(forKey: "input") }
        body["drawings"] = drawings
        body["pictures"] = pictures
        body["title"] = title
        let json = try JSONSerialization.data(withJSONObject: body)
        guard let text = String(data: json, encoding: .utf8) else { throw EngineError.failed("request") }
        let started = Date()
        guard let raw = hd_export(text) else { throw EngineError.failed("no answer") }
        defer { hd_free(raw) }
        let answer = String(cString: raw)
        Log.info("engine export \(output.lastPathComponent): \(answer) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s, \(drawings.count) drawings, \(pictures.count) pictures")
        guard let data = answer.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.failed(answer)
        }
        guard object["ok"] as? Bool == true else {
            if object["wrongPassword"] as? Bool == true { throw EngineError.wrongPassword }
            if object["needsPassword"] as? Bool == true { throw EngineError.needsPassword }
            throw EngineError.failed(object["error"] as? String ?? answer)
        }
        return ExportAnswer(pages: object["pages"] as? Int ?? 0,
                            drawings: object["drawings"] as? Int ?? 0,
                            onPages: object["onPages"] as? Int ?? 0,
                            skippedPages: object["skippedPages"] as? [Int] ?? [])
    }

    private func convertNow(_ request: Request) throws -> EngineReport {
        let body = options(request)
        let json = try JSONSerialization.data(withJSONObject: body)
        guard let text = String(data: json, encoding: .utf8) else { throw EngineError.failed("request") }
        let started = Date()
        guard let raw = hd_convert(text) else { throw EngineError.failed("no answer") }
        defer { hd_free(raw) }
        let answer = String(cString: raw)
        Log.info("engine \(request.input.lastPathComponent): \(answer) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        guard let data = answer.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.failed(answer)
        }
        guard object["ok"] as? Bool == true else {
            if object["wrongPassword"] as? Bool == true { throw EngineError.wrongPassword }
            if object["needsPassword"] as? Bool == true { throw EngineError.needsPassword }
            throw EngineError.failed(object["error"] as? String ?? answer)
        }
        return EngineReport(
            armsciiRuns: object["armsciiRuns"] as? Int ?? 0,
            fallbackRuns: object["fallbackRuns"] as? Int ?? 0,
            missingFonts: object["missingFonts"] as? [String] ?? [],
            legacyFonts: object["legacyFonts"] as? [String] ?? []
        )
    }
}
