import Foundation
import UIKit

/// Launch arguments used only by the UI tests that run in the cloud build.
enum TestHooks {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isUITest: Bool { arguments.contains("-uitest") }
    /// Write diagnostic files (logs, rendered PDFs, page HTML) to Documents/Debug.
    static var dumpEnabled: Bool { arguments.contains("-uitest-dump") }

    static func applyLaunchArguments() {
        if arguments.contains("-uitest-reset") {
            let fm = FileManager.default
            try? fm.removeItem(at: DocumentLibrary.libraryRoot)
            try? fm.removeItem(at: debugFolder)
        }
        if isUITest {
            // The simulator has no Apple Pencil: let a finger (the test's drag) draw.
            UserDefaults.standard.set(true, forKey: AppSettings.Key.fingerDrawing)
            UIView.setAnimationsEnabled(false)
        }
    }

    static var debugFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Debug", isDirectory: true)
    }

    static func dump(_ name: String, text: String) {
        guard dumpEnabled else { return }
        dump(name, data: Data(text.utf8))
    }

    static func dump(_ name: String, data: Data) {
        guard dumpEnabled else { return }
        let folder = debugFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(name))
    }
}

/// Small logger: unified log always, plus Documents/Debug/log.txt during UI tests.
enum Log {
    private static let queue = DispatchQueue(label: "haydocs.log")

    static func info(_ message: String) {
        NSLog("[HayDocs] %@", message)
        guard TestHooks.dumpEnabled else { return }
        let line = "\(Date()) \(message)\n"
        queue.async {
            let folder = TestHooks.debugFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("log.txt")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
