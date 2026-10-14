import AppKit
import Foundation
import PeelUI
import UniformTypeIdentifiers

/// The system's file panels and the Finder, in one place: picking files to
/// open, where to save one, and showing one. No panels offscreen.
@MainActor
struct FilePanels: FilePicking {
    /// Files picked in an open panel beside the window, of the given types
    /// if any; nil when the panel was cancelled.
    func open(
        prompt: String? = nil, multiple: Bool, directories: Bool = false, types: [UTType] = []
    ) -> [URL]? {
        guard !Offscreen.refuses("an open panel") else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        if !types.isEmpty { panel.allowedContentTypes = types }
        if let prompt { panel.prompt = prompt }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// Where to save a file, picked in a save panel that starts with `name`;
    /// nil when it was cancelled.
    func saveLocation(named name: String) -> URL? {
        guard !Offscreen.refuses("a save panel") else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Shows a file in the Finder, selected. Never opens it.
    func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
