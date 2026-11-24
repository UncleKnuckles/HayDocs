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

    private func convertNow(_ request: Request) throws -> EngineReport {
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
