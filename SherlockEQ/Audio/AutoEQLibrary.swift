import Foundation

/// Lists AutoEQ-format `.txt` files in the user's configured library
/// folder. `AudioState.autoEQPreferences.libraryFolder` holds the directory; when
/// it's set, Profile Detail's Headphone-correction picker shows these
/// entries directly so users don't have to NSOpenPanel a file every time.
nonisolated enum AutoEQLibrary {

    struct Entry: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: URL { url }
    }

    static func entries(in folder: URL?) -> [Entry] {
        guard let folder else { return [] }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "txt" }
            .map { Entry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
