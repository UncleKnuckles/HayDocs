import SwiftUI

@main
struct HayDocsApp: App {
    @StateObject private var library = DocumentLibrary.shared
    @StateObject private var fonts = FontLibrary.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        TestHooks.applyLaunchArguments()
        FontLibrary.shared.registerAllFonts()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(fonts)
                .tint(Theme.accent)
                .onOpenURL { url in
                    library.importFiles([url])
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        library.importFromAppFolder()
                    }
                }
        }

        // A second window for a document (two documents side by side on iPhone Duo and iPad).
        WindowGroup("Документ", id: "reader", for: UUID.self) { $documentID in
            ReaderWindowRoot(documentID: documentID)
                .environmentObject(library)
                .environmentObject(fonts)
                .tint(Theme.accent)
        }
    }
}

struct ReaderWindowRoot: View {
    let documentID: UUID?
    @EnvironmentObject private var library: DocumentLibrary

    var body: some View {
        NavigationStack {
            if let id = documentID, let document = library.document(with: id) {
                ReaderScreen(document: document)
            } else {
                ContentUnavailableView("Документ не найден", systemImage: "doc.questionmark")
            }
        }
    }
}

enum Theme {
    /// One quiet accent colour; everything else is the system's neutral palette.
    static let accent = Color(red: 0.13, green: 0.36, blue: 0.85)
}
