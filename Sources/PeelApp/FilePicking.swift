import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// The system's file panels and the Finder, in one place: picking files to
/// open, where to save one, and showing one. No panels offscreen.
@MainActor
enum FilePicking {
    /// Files picked in an open panel beside the window, of the given types
    /// if any; nil when the panel was cancelled.
    static func open(
        prompt: String? = nil, multiple: Bool, directories: Bool = false, types: [UTType] = []
    ) -> [URL]? {
        #if os(macOS)
        guard !Offscreen.refuses("an open panel") else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        if !types.isEmpty { panel.allowedContentTypes = types }
        if let prompt { panel.prompt = prompt }
        return panel.runModal() == .OK ? panel.urls : nil
        #else
        return nil
        #endif
    }

    /// Where to save a file, picked in a save panel that starts with `name`;
    /// nil when it was cancelled.
    static func saveLocation(named name: String) -> URL? {
        #if os(macOS)
        guard !Offscreen.refuses("a save panel") else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    /// Shows a file in the Finder, selected. Never opens it.
    static func reveal(_ file: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        #endif
    }
}
