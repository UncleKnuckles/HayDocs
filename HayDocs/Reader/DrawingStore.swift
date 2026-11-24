import Foundation
import PencilKit

/// Keeps one PencilKit drawing per page in `<document>/drawings/<page>.drawing`, plus the size
/// of the canvas each drawing was made on (sizes.json), so exports can map it onto the page.
@MainActor
final class DrawingStore {
    let folder: URL
    private var drawings: [Int: PKDrawing] = [:]
    private var canvasSizes: [Int: CGSize] = [:]
    private var dirty: Set<Int> = []
    private var saveTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    private var sizesURL: URL { folder.appendingPathComponent("sizes.json") }

    private func fileURL(for page: Int) -> URL {
        folder.appendingPathComponent("\(page).drawing")
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "drawing" {
            guard let page = Int(file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let drawing = try? PKDrawing(data: data) else { continue }
            drawings[page] = drawing
        }
        if let data = try? Data(contentsOf: sizesURL),
           let sizes = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            for (key, value) in sizes where value.count == 2 {
                if let page = Int(key) { canvasSizes[page] = CGSize(width: value[0], height: value[1]) }
            }
        }
    }

    func drawing(for page: Int) -> PKDrawing {
        drawings[page] ?? PKDrawing()
    }

    func nonEmptyDrawing(for page: Int) -> PKDrawing? {
        guard let drawing = drawings[page], !drawing.strokes.isEmpty else { return nil }
        return drawing
    }

    func canvasSize(for page: Int) -> CGSize? {
        canvasSizes[page]
    }

    var hasDrawings: Bool {
        drawings.values.contains { !$0.strokes.isEmpty }
    }

    /// Pages that have ink, with their drawings.
    var allDrawings: [Int: PKDrawing] {
        drawings.filter { !$0.value.strokes.isEmpty }
    }

    var allCanvasSizes: [Int: CGSize] { canvasSizes }

    func update(_ drawing: PKDrawing, canvasSize: CGSize, for page: Int) {
        drawings[page] = drawing
        if canvasSize.width > 1, canvasSize.height > 1 {
            canvasSizes[page] = canvasSize
        }
        dirty.insert(page)
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard !dirty.isEmpty else { return }
        for page in dirty {
            let url = fileURL(for: page)
            if let drawing = drawings[page], !drawing.strokes.isEmpty {
                try? drawing.dataRepresentation().write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        dirty.removeAll()
        var sizes: [String: [Double]] = [:]
        for (page, size) in canvasSizes {
            sizes[String(page)] = [Double(size.width), Double(size.height)]
        }
        if let data = try? JSONEncoder().encode(sizes) {
            try? data.write(to: sizesURL, options: .atomic)
        }
    }
}
