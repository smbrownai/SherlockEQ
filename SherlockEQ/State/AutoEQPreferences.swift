import Foundation
import Combine

/// AutoEQ-specific preferences — currently just the user-selected
/// correction library folder. Extracted from AudioState so view
/// surfaces that browse the AutoEQ library (ProfileDetailView,
/// AutoEQSearchView) can depend on this without pulling in the
/// whole audio pipeline.
@MainActor
final class AutoEQPreferences: ObservableObject {

    /// User-selected library folder containing AutoEQ correction `.txt`
    /// files. When set, the Headphone-correction picker on Profile Detail
    /// offers a menu listing every `.txt` in this folder in addition to
    /// the "From file…" import. Nil means library disabled; user only sees
    /// the file picker. Stored as a plain path string in UserDefaults
    /// (sandbox is OFF, so we don't need security-scoped bookmarks).
    @Published var libraryFolder: URL? = AutoEQPreferences.loadURL(key: AutoEQPreferences.libraryFolderKey) {
        didSet {
            if let url = libraryFolder {
                UserDefaults.standard.set(url.path, forKey: Self.libraryFolderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.libraryFolderKey)
            }
        }
    }

    private static let libraryFolderKey = "sherlockeq.autoEQLibraryFolder"

    private static func loadURL(key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
