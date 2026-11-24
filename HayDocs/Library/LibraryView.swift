import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct LibraryView: View {
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.openWindow) private var openWindow

    @State private var path: [UUID] = []
    @State private var query = ""
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var showNotebook = false
    @State private var showFonts = false
    @State private var showSettings = false
    @State private var renaming: LibraryDocument?
    @State private var renameText = ""
    @State private var deleting: LibraryDocument?

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 18)]

    private var visibleDocuments: [LibraryDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.documents }
        return library.documents.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Документы")
                .toolbar { toolbar }
                .navigationDestination(for: UUID.self) { id in
                    if let document = library.document(with: id) {
                        ReaderScreen(document: document)
                    }
                }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: ImportTypes.documents,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                library.importFiles(urls)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 60, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await importPhotos(items) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                Task { await library.importImages(images, title: "Скан \(DocumentLibrary.shortDate.string(from: Date()))", kind: .scan) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showNotebook) {
            NotebookSheet { pages, style, paper in
                library.createNotebook(pages: pages, style: style, paper: paper)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showFonts) {
            NavigationStack { FontsView() }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Готово") {
                if let document = renaming { library.rename(document, to: renameText) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Удалить документ вместе с рисунками?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let document = deleting { library.delete(document) }
                deleting = nil
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        }
        .alert(library.message?.title ?? "", isPresented: Binding(get: { library.message != nil },
                                                                  set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) { library.message = nil }
        } message: {
            Text(library.message?.text ?? "")
        }
        .overlay(alignment: .bottom) {
            if let job = library.activeImports.first {
                ImportBanner(name: job.name, more: library.activeImports.count - 1)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: library.activeImports)
    }

    @ViewBuilder
    private var content: some View {
        if library.documents.isEmpty {
            EmptyLibraryView(
                openFiles: { showFilePicker = true },
                addSamples: { Task { await library.addSamples() } }
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach(visibleDocuments) { document in
                        Button {
                            path.append(document.id)
                        } label: {
                            DocumentCard(document: document)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("doc-\(document.title)")
                        .contextMenu { menu(for: document) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .searchable(text: $query, prompt: "Поиск")
            .scrollDismissesKeyboard(.immediately)
        }
    }

    @ViewBuilder
    private func menu(for document: LibraryDocument) -> some View {
        if UIApplication.shared.supportsMultipleScenes {
            Button {
                openWindow(id: "reader", value: document.id)
            } label: {
                Label("Открыть в новом окне", systemImage: "macwindow.badge.plus")
            }
        }
        Button {
            renameText = document.title
            renaming = document
        } label: {
            Label("Переименовать", systemImage: "pencil")
        }
        Button {
            library.duplicate(document)
        } label: {
            Label("Дублировать", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            deleting = document
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { showFonts = true } label: { Label("Шрифты", systemImage: "textformat") }
                    .accessibilityIdentifier("openFonts")
                Button { showSettings = true } label: { Label("Настройки", systemImage: "gearshape") }
                    .accessibilityIdentifier("openSettings")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("libraryMenu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showFilePicker = true } label: { Label("Файлы", systemImage: "folder") }
                Button { showPhotoPicker = true } label: { Label("Фото", systemImage: "photo") }
                if VNDocumentCameraViewController.isSupported {
                    Button { showScanner = true } label: { Label("Сканировать", systemImage: "doc.viewfinder") }
                }
                Button { showNotebook = true } label: { Label("Новый блокнот", systemImage: "square.and.pencil") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier("addMenu")
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        await library.importImages(images, title: "Фото \(DocumentLibrary.shortDate.string(from: Date()))", kind: .image)
    }
}

private struct ImportBanner: View {
    let name: String
    let more: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(more > 0 ? "Открываю «\(name)» и ещё \(more)" : "Открываю «\(name)»")
                .font(.footnote)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 24)
    }
}

private struct EmptyLibraryView: View {
    let openFiles: () -> Void
    let addSamples: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Пока пусто")
                    .font(.title3.weight(.semibold))
                Text("PDF, Word, ODT и другие документы.\nРисуйте поверх страниц Apple Pencil.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: openFiles) {
                Text("Открыть файл")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("openFiles")
            Button("Добавить примеры", action: addSamples)
                .font(.subheadline)
                .accessibilityIdentifier("addSamples")
            Spacer()
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DocumentCard: View {
    let document: LibraryDocument
    @EnvironmentObject private var library: DocumentLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailView(url: library.thumbnailURL(for: document), revision: library.thumbnailRevision)
                .aspectRatio(0.707, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(document.kind.label) · \(document.pageCount) стр.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ThumbnailView: View {
    let url: URL
    let revision: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
                    .font(.largeTitle.weight(.ultraLight))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: "\(url.path)#\(revision)") {
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

struct NotebookSheet: View {
    let create: (Int, NotebookStyle, PaperSize) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pages = 10
    @State private var style: NotebookStyle = .lined
    @State private var paper: PaperSize = AppSettings.paper

    var body: some View {
        NavigationStack {
            Form {
                Picker("Страницы", selection: $style) {
                    ForEach(NotebookStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Stepper("Страниц: \(pages)", value: $pages, in: 1...200)
                Picker("Формат", selection: $paper) {
                    ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                }
            }
            .navigationTitle("Новый блокнот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        create(pages, style, paper)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let dismiss: () -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, dismiss: @escaping () -> Void) {
            self.onFinish = onFinish
            self.dismiss = dismiss
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            onFinish(images)
            dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            dismiss()
        }
    }
}
