import Foundation
import CoreGraphics

/// User preferences (UserDefaults). Views use @AppStorage with the same keys.
enum AppSettings {
    enum Key {
        static let armscii = "armsciiConversion"
        static let fingerDrawing = "fingerDrawing"
        static let serifFallback = "serifFallbackFamily"
        static let sansFallback = "sansFallbackFamily"
        static let monoFallback = "monoFallbackFamily"
        static let paper = "paperSize"
    }

    static let defaultSerif = "Noto Serif Armenian"
    static let defaultSans = "Noto Sans Armenian"
    static let defaultMono = "DejaVu Sans Mono"

    private static var defaults: UserDefaults { .standard }

    /// Convert text typed in old 8-bit Armenian fonts (ArmSCII: "Arial Armenian", "Times Armenian"…)
    /// to real Unicode Armenian.
    static var armsciiConversion: Bool {
        defaults.object(forKey: Key.armscii) as? Bool ?? true
    }

    /// Draw with a finger too (otherwise only Apple Pencil draws and a finger scrolls).
    static var fingerDrawing: Bool {
        defaults.bool(forKey: Key.fingerDrawing)
    }

    static var serifFallback: String {
        nonEmpty(defaults.string(forKey: Key.serifFallback)) ?? defaultSerif
    }

    static var sansFallback: String {
        nonEmpty(defaults.string(forKey: Key.sansFallback)) ?? defaultSans
    }

    static var monoFallback: String {
        nonEmpty(defaults.string(forKey: Key.monoFallback)) ?? defaultMono
    }

    /// Paper for documents that have no page size of their own (plain text, HTML).
    static var paper: PaperSize {
        PaperSize(rawValue: defaults.string(forKey: Key.paper) ?? "") ?? .a4
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4"
    case letter = "Letter"

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }

    var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter (США)"
        }
    }
}
