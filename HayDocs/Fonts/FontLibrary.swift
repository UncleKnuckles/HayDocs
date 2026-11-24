import CoreText
import Foundation
import UIKit

/// One face of a font file (a family can have several: Regular, Bold…).
struct FontFace: Identifiable, Hashable {
    enum Source: String { case bundled, imported }

    let id: String            // PostScript name
    let family: String
    let styleName: String
    let fileURL: URL
    let source: Source
    let weight: Int           // CSS weight 100…900
    let weightRange: String   // "400", or "100 900" for a variable font
    let italic: Bool
    let isVariable: Bool
    let supportsArmenian: Bool

    var displayName: String {
        styleName.isEmpty ? family : "\(family) \(styleName)"
    }
}

enum FontImportError: LocalizedError {
    case unreadable(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Файл «\(name)» не похож на шрифт."
        case .unsupported(let name): return "Шрифт «\(name)» не поддерживается (нужен .ttf или .otf)."
        }
    }
}

/// Fonts the app ships with (free fonts that cover Armenian) and fonts the person adds.
/// All are registered for this app, so the interface can show them, and are handed to the
/// document renderer by name.
@MainActor
final class FontLibrary: ObservableObject {
    static let shared = FontLibrary()
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    @Published private(set) var bundledFaces: [FontFace] = []
    @Published private(set) var importedFaces: [FontFace] = []
    @Published private(set) var systemArmenianFamilies: [String] = []

    let importedFolder: URL
    private var registeredFiles: Set<URL> = []
    private var base64Cache: [URL: String] = [:]

    init() {
        importedFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HayDocs/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
    }

    var allFaces: [FontFace] { bundledFaces + importedFaces }

    /// Families with Armenian letters, for the "default Armenian font" pickers.
    var armenianFamilies: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for family in allFaces.filter(\.supportsArmenian).map(\.family) + systemArmenianFamilies
        where seen.insert(family).inserted {
            result.append(family)
        }
        return result
    }

    func registerAllFonts() {
        let bundledFolder = Bundle.main.url(forResource: "Fonts", withExtension: nil)
        bundledFaces = bundledFolder.map { loadFaces(in: $0, source: .bundled) } ?? []
        importedFaces = loadFaces(in: importedFolder, source: .imported)
        systemArmenianFamilies = Self.findSystemArmenianFamilies(excluding: Set(allFaces.map(\.family)))
        Log.info("fonts: \(bundledFaces.count) bundled, \(importedFaces.count) imported, system Armenian: \(systemArmenianFamilies)")
        // The document engine draws the pages with the same files.
        WordEngine.shared.addFonts(Array(Set(allFaces.map(\.fileURL))).sorted { $0.path < $1.path })
    }

    private func loadFaces(in folder: URL, source: FontFace.Source) -> [FontFace] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.fontExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var faces: [FontFace] = []
        for file in files {
            register(file)
            faces.append(contentsOf: Self.faces(in: file, source: source))
        }
        return faces.sorted { ($0.family, $0.weight, $0.italic ? 1 : 0) < ($1.family, $1.weight, $1.italic ? 1 : 0) }
    }

    private func register(_ file: URL) {
        guard !registeredFiles.contains(file) else { return }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
            registeredFiles.insert(file)
        } else {
            // Already registered (or a system font of the same name): still usable by name.
            registeredFiles.insert(file)
            if let e = error?.takeRetainedValue() {
                Log.info("font register \(file.lastPathComponent): \(e)")
            }
        }
    }

    func importFont(from url: URL) throws -> [FontFace] {
        let ext = url.pathExtension.lowercased()
        guard Self.fontExtensions.contains(ext) else { throw FontImportError.unsupported(url.lastPathComponent) }
        let probe = Self.faces(in: url, source: .imported)
        guard !probe.isEmpty else { throw FontImportError.unreadable(url.lastPathComponent) }

        var target = importedFolder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            // The same file again: replace it.
            unregister(target)
            try? FileManager.default.removeItem(at: target)
            importedFaces.removeAll { $0.fileURL == target }
        }
        target = importedFolder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: target)
        register(target)
        WordEngine.shared.addFonts([target])
        let faces = Self.faces(in: target, source: .imported)
        importedFaces = (importedFaces + faces).sorted { ($0.family, $0.weight) < ($1.family, $1.weight) }
        systemArmenianFamilies = Self.findSystemArmenianFamilies(excluding: Set(allFaces.map(\.family)))
        return faces
    }

    func remove(_ face: FontFace) {
        guard face.source == .imported else { return }
        unregister(face.fileURL)
        try? FileManager.default.removeItem(at: face.fileURL)
        importedFaces.removeAll { $0.fileURL == face.fileURL }
        base64Cache[face.fileURL] = nil
    }

    private func unregister(_ file: URL) {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerUnregisterFontsForURL(file as CFURL, .process, &error)
        registeredFiles.remove(file)
    }

    /// Faces whose family matches `name` (case, spaces and dashes ignored).
    func faces(forFamily name: String) -> [FontFace] {
        let key = Self.normalized(name)
        return allFaces.filter { Self.normalized($0.family) == key }
    }

    func hasFamily(_ name: String) -> Bool {
        let key = Self.normalized(name)
        return allFaces.contains { Self.normalized($0.family) == key }
            || systemArmenianFamilies.contains { Self.normalized($0) == key }
    }

    func base64(for face: FontFace) -> String? {
        if let cached = base64Cache[face.fileURL] { return cached }
        guard let data = try? Data(contentsOf: face.fileURL) else { return nil }
        let encoded = data.base64EncodedString()
        base64Cache[face.fileURL] = encoded
        return encoded
    }

    /// The face the interface previews a family with.
    func previewFontName(for family: String) -> String? {
        let faces = faces(forFamily: family)
        return (faces.first { $0.weight == 400 && !$0.italic } ?? faces.first)?.id
            ?? UIFont.fontNames(forFamilyName: family).first
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Reading font files

    nonisolated static func faces(in file: URL, source: FontFace.Source) -> [FontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        var result: [FontFace] = []
        for descriptor in descriptors {
            let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
            let postscript = CTFontCopyPostScriptName(font) as String
            let family = (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String)
                ?? (CTFontCopyFamilyName(font) as String)
            let style = (CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String) ?? ""
            let traits = CTFontCopyTraits(font) as NSDictionary
            let symbolic = (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0
            let weightValue = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
            let italic = (symbolic & CTFontSymbolicTraits.traitItalic.rawValue) != 0
                || style.lowercased().contains("italic") || style.lowercased().contains("oblique")
            let axes = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
            var weightRange = String(cssWeight(weightValue, style: style))
            if let wght = axes.first(where: { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == 0x7767_6874 }),
               let lo = (wght[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
               let hi = (wght[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue {
                weightRange = "\(Int(max(1, lo))) \(Int(min(1000, hi)))"
            }
            let armenian = CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(font), 0x0531)
            result.append(FontFace(
                id: postscript,
                family: family,
                styleName: style,
                fileURL: file,
                source: source,
                weight: cssWeight(weightValue, style: style),
                weightRange: weightRange,
                italic: italic,
                isVariable: !axes.isEmpty,
                supportsArmenian: armenian
            ))
        }
        return result
    }

    nonisolated private static func cssWeight(_ value: Double, style: String) -> Int {
        let s = style.lowercased()
        if s.contains("thin") || s.contains("hairline") { return 100 }
        if s.contains("extralight") || s.contains("ultralight") { return 200 }
        if s.contains("semibold") || s.contains("demibold") { return 600 }
        if s.contains("extrabold") || s.contains("ultrabold") { return 800 }
        if s.contains("black") || s.contains("heavy") { return 900 }
        if s.contains("bold") { return 700 }
        if s.contains("medium") { return 500 }
        if s.contains("light") { return 300 }
        let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min { abs($0.0 - value) < abs($1.0 - value) }?.1 ?? 400
    }

    nonisolated static func findSystemArmenianFamilies(excluding: Set<String>) -> [String] {
        var result: [String] = []
        for family in UIFont.familyNames.sorted() where !excluding.contains(family) {
            guard let name = UIFont.fontNames(forFamilyName: family).first else { continue }
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            if CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(font), 0x0531) {
                result.append(family)
            }
        }
        return result
    }
}
