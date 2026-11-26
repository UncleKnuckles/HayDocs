import SwiftUI
import UIKit

/// One document: pages, drawing with Apple Pencil, export. Two toolbar buttons and two menus.
struct ReaderScreen: View {
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: ReaderController
    @State private var showSearch = false
    @State private var showInfo = false
    @State private var confirmClear = false
    @State private var badgeVisible = true

    private let documentID: UUID

    init(document: LibraryDocument) {
        documentID = document.id
        _controller = StateObject(wrappedValue: ReaderController(document: document, library: DocumentLibrary.shared))
    }

    private var title: String {
        library.document(with: documentID)?.title ?? controller.title
    }

    var body: some View {
        PDFReaderView(controller: controller)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) { pageBadge }
            .overlay {
                if controller.isBusy {
                    ProgressView(controller.busyText)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(controller.isDrawing)
            .toolbar { toolbar }
            .sheet(isPresented: $showSearch) {
                SearchSheet(controller: controller)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showInfo) {
                DocumentInfoSheet(documentID: documentID)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Стереть рисунок на этой странице?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Стереть", role: .destructive) { controller.clearCurrentPage() }
                Button("Отмена", role: .cancel) {}
            }
            .alert("Не получилось", isPresented: Binding(get: { controller.errorText != nil },
                                                         set: { if !$0 { controller.errorText = nil } })) {
                Button("OK", role: .cancel) { controller.errorText = nil }
            } message: {
                Text(controller.errorText ?? "")
            }
            .onDisappear { controller.close() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { controller.saveDrawings() }
            }
            .task(id: controller.currentPage) {
                badgeVisible = true
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation(.easeOut(duration: 0.4)) { badgeVisible = false }
            }
    }

    @ViewBuilder
    private var pageBadge: some View {
        if controller.pageCount > 1 && badgeVisible {
            Text("\(controller.currentPage + 1) из \(controller.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, controller.showThumbnails ? 84 : 18)
                .allowsHitTesting(false)
                .accessibilityIdentifier("pageBadge")
                .transition(.opacity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if controller.isDrawing {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!controller.canUndo)
                    .accessibilityLabel("Отменить")
                    .accessibilityIdentifier("undo")
                Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!controller.canRedo)
                    .accessibilityLabel("Повторить")
                    .accessibilityIdentifier("redo")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { controller.setDrawing(false) }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("doneDrawing")
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { controller.setDrawing(true) } label: { Image(systemName: "pencil.tip.crop.circle") }
                    .accessibilityLabel("Рисовать")
                    .accessibilityIdentifier("drawToggle")
                exportMenu
                moreMenu
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Section("С рисунками") {
                Button { controller.export(.pdfWithDrawings) } label: { Label("PDF", systemImage: "doc.richtext") }
                    .accessibilityIdentifier("exportPDFWithDrawings")
                Button { controller.export(.word) } label: { Label("Word (.docx)", systemImage: "doc.text") }
                    .accessibilityIdentifier("exportWord")
                Button { controller.export(.odt) } label: { Label("ODT (OpenDocument)", systemImage: "doc.text") }
                    .accessibilityIdentifier("exportODT")
                Menu {
                    Button { controller.export(.pageImage) } label: { Label("Эта страница", systemImage: "photo") }
                        .accessibilityIdentifier("exportPageImage")
                    Button { controller.export(.allPageImages) } label: { Label("Все страницы", systemImage: "photo.stack") }
                        .accessibilityIdentifier("exportAllPageImages")
                } label: {
                    Label("Картинки страниц (PNG)", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("exportImagesMenu")
            }
            Section {
                Button { controller.export(.pdfClean) } label: { Label("PDF без рисунков", systemImage: "doc") }
                if controller.hasOriginal {
                    Button { controller.export(.originalFile) } label: { Label("Исходный файл", systemImage: "doc.badge.arrow.up") }
                }
            }
            Section {
                Button { controller.printDocument() } label: { Label("Напечатать", systemImage: "printer") }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Поделиться")
        .accessibilityIdentifier("exportMenu")
    }

    private var moreMenu: some View {
        Menu {
            Button { showSearch = true } label: { Label("Найти в тексте", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("searchButton")
            Toggle(isOn: $controller.showThumbnails) { Label("Миниатюры страниц", systemImage: "rectangle.grid.1x2") }
            Toggle(isOn: Binding(get: { controller.twoPages }, set: { controller.setTwoPages($0) })) {
                Label("Разворот", systemImage: "book")
            }
            Menu {
                ForEach(NotebookStyle.allCases) { style in
                    Button(style.title) { controller.appendBlankPage(style: style) }
                }
            } label: {
                Label("Добавить страницу", systemImage: "plus.rectangle.portrait")
            }
            Divider()
            Toggle(isOn: Binding(get: { controller.fingerDrawing }, set: { controller.setFingerDrawing($0) })) {
                Label("Рисовать пальцем", systemImage: "hand.draw")
            }
            if controller.currentPageHasDrawing {
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Стереть рисунок на странице", systemImage: "eraser")
                }
            }
            Divider()
            if controller.canRerender {
                Button { Task { await controller.rerender() } } label: {
                    Label("Перерисовать страницы", systemImage: "arrow.clockwise")
                }
            }
            Button { showInfo = true } label: { Label("О документе", systemImage: "info.circle") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Ещё")
        .accessibilityIdentifier("moreMenu")
    }
}

/// Search in the document's text; a tap shows the place.
struct SearchSheet: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty && controller.searchResults.isEmpty {
                    Text("Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.searchResults) { hit in
                    Button {
                        controller.show(hit)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Стр. \(hit.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(hit.snippet)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Слово или фраза")
            .onSubmit(of: .search) { controller.search(query) }
            .onChange(of: query) { _, text in
                if text.count >= 2 || text.isEmpty { controller.search(text) }
            }
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

/// What the document is and what was done to show it.
struct DocumentInfoSheet: View {
    let documentID: UUID
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let document = library.document(with: documentID) {
                    Section {
                        LabeledContent("Тип", value: document.kind.label)
                        LabeledContent("Страниц", value: "\(document.pageCount)")
                        if !document.originalFileName.isEmpty {
                            LabeledContent("Файл", value: document.originalFileName)
                        }
                        LabeledContent("Добавлен", value: DocumentLibrary.shortDate.string(from: document.created))
                        LabeledContent("Изменён", value: DocumentLibrary.shortDate.string(from: document.modified))
                    }
                    if !document.notes.isEmpty {
                        Section("Как показан") {
                            ForEach(document.notes, id: \.self) { note in
                                Text(note).font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("О документе")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}
