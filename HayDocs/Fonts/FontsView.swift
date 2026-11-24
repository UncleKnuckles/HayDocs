import SwiftUI
import UniformTypeIdentifiers

/// Fonts that come with the app, fonts the person added (.ttf, .otf), and a preview of each.
struct FontsView: View {
    @EnvironmentObject private var fonts: FontLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var message: String?
    @State private var sample = "Բարև ձեզ։ Привет! Hello."

    private struct Family: Identifiable {
        let name: String
        let faces: [FontFace]
        var id: String { name }
        var armenian: Bool { faces.contains(where: \.supportsArmenian) }
    }

    private func families(_ faces: [FontFace]) -> [Family] {
        Dictionary(grouping: faces, by: \.family)
            .map { Family(name: $0.key, faces: $0.value) }
            .sorted { ($0.armenian ? 0 : 1, $0.name) < ($1.armenian ? 0 : 1, $1.name) }
    }

    var body: some View {
        List {
            Section {
                TextField("Текст для примера", text: $sample)
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("Шрифты из документа, которых нет в телефоне, заменяются похожими. Добавьте нужные файлы .ttf или .otf, и армянский текст будет показан ими.")
            }

            Section("Добавленные") {
                if fonts.importedFaces.isEmpty {
                    Button { showImporter = true } label: {
                        Label("Добавить шрифт", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addFont")
                }
                ForEach(families(fonts.importedFaces)) { family in
                    FamilyRow(name: family.name, faces: family.faces, sample: sample, armenian: family.armenian)
                        .swipeActions {
                            Button(role: .destructive) {
                                family.faces.forEach(fonts.remove)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }

            Section("В приложении") {
                ForEach(families(fonts.bundledFaces)) { family in
                    FamilyRow(name: family.name, faces: family.faces, sample: sample, armenian: family.armenian)
                }
            }

            if !fonts.systemArmenianFamilies.isEmpty {
                Section("В системе, с армянскими буквами") {
                    ForEach(fonts.systemArmenianFamilies, id: \.self) { family in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(family).font(.caption).foregroundStyle(.secondary)
                            Text(sample).font(.custom(family, size: 18)).lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Шрифты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Закрыть") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить шрифт")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: ImportTypes.fonts, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var added: [String] = []
            var failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let faces = try fonts.importFont(from: url)
                    added.append(contentsOf: faces.map(\.displayName))
                } catch {
                    failed.append(error.localizedDescription)
                }
            }
            var lines: [String] = []
            if !added.isEmpty {
                lines.append("Добавлено: \(added.joined(separator: ", ")).")
                lines.append("Для уже открытых документов выберите в меню документа «Перерисовать страницы».")
            }
            lines.append(contentsOf: failed)
            message = lines.joined(separator: "\n")
        }
        .alert("Шрифты", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

private struct FamilyRow: View {
    let name: String
    let faces: [FontFace]
    let sample: String
    let armenian: Bool
    @EnvironmentObject private var fonts: FontLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if armenian {
                    Text("Հայ")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Text(faces.count == 1 ? (faces[0].isVariable ? "переменный" : faces[0].styleName) : "\(faces.count) начертания")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let postscript = fonts.previewFontName(for: name) {
                Text(sample)
                    .font(.custom(postscript, size: 18))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
