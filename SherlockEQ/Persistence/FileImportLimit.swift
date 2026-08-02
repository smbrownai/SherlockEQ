import Foundation

/// Shared ceiling for user-picked file imports.
///
/// AutoEQ `.txt` correction files, exported profile JSON, and standalone
/// audiogram JSON are each read whole into memory on the calling (main) thread
/// the moment the user picks them in an open panel. Without a bound, a
/// pathologically large — or simply wrong — file blocks the UI while
/// Foundation buffers the entire thing, then hands the decoder something
/// absurd.
///
/// The remote AutoEQ fetch already caps response bodies at the same 8 MB
/// (audit SEC-02, `AutoEQRemoteService.maxResponseBytes`); this is the
/// local-file counterpart (audit F-1). Real inputs are tiny — a filter file is
/// a few KB, a profile or audiogram a few KB — so 8 MB is orders of magnitude
/// of headroom while still refusing a runaway file.
///
/// The size is read from the filesystem's own metadata (`.fileSizeKey`), so an
/// over-limit file is refused *before* any of its bytes are read. Every input
/// here is a regular local file the user chose in `NSOpenPanel`, for which the
/// size attribute is always present; if it is somehow unavailable we let the
/// read proceed rather than block a legitimate small file on an attribute
/// quirk.
enum FileImportLimit {

    /// Upper bound, in bytes, for any single user-picked import.
    static let maxBytes = 8 * 1024 * 1024

    /// Thrown when a picked file is larger than `maxBytes`. Its
    /// `errorDescription` is what reaches the user — via `ProfileStore`'s
    /// `tracking` wrapper (→ notice banner) for profile / audiogram imports,
    /// and via an explicit notice for the AutoEQ text import.
    struct FileTooLargeError: LocalizedError, Equatable {
        /// The file's reported size, when the filesystem gave us one.
        let byteCount: Int?

        var errorDescription: String? {
            let cap = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
            if let byteCount {
                let got = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
                return "The file is too large to import (\(got); the limit is \(cap))."
            }
            return "The file is too large to import (the limit is \(cap))."
        }
    }

    /// Throw `FileTooLargeError` if `url` is larger than `maxBytes`. Reads only
    /// the filesystem's size metadata — never any file contents.
    static func check(_ url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > maxBytes {
            throw FileTooLargeError(byteCount: size)
        }
    }

    /// `Data(contentsOf:)` guarded by the size check.
    static func data(at url: URL) throws -> Data {
        try check(url)
        return try Data(contentsOf: url)
    }

    /// `String(contentsOf:encoding:)` guarded by the size check.
    static func string(at url: URL, encoding: String.Encoding = .utf8) throws -> String {
        try check(url)
        return try String(contentsOf: url, encoding: encoding)
    }
}
