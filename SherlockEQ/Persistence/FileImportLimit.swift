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

    /// Thrown when a `dataNoFollow` open hit a symlink at the final path
    /// component. Kept distinct from a plain read failure so the CLI can report
    /// the refusal precisely.
    struct SymlinkRefusedError: LocalizedError, Equatable {
        let name: String
        var errorDescription: String? {
            "Refusing to import through a symlink (\(name))."
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

    /// Bytes of the file at `url`, read through an `O_NOFOLLOW` open so a
    /// symlink at the final path component is refused *at open time*.
    ///
    /// Use this for paths that arrived from an untrusted, unauthenticated
    /// caller — the CLI control port (audit I-1) — where the separate lstat
    /// check the handler already does leaves a time-of-check/time-of-use gap:
    /// the path can be swapped for a symlink between that check and the read.
    /// Opening the very descriptor we then read from, with the kernel enforcing
    /// `O_NOFOLLOW`, closes the race. The 8 MB cap (F-1) is applied on the same
    /// descriptor, so the size check can't be raced either. `data(at:)` — which
    /// follows symlinks — stays the path for user-picked GUI imports, where the
    /// file was just chosen in an open panel.
    static func dataNoFollow(at url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                throw SymlinkRefusedError(name: url.lastPathComponent)
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
        // FileHandle takes ownership and closes the descriptor on dealloc,
        // including if the read below throws.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Read one byte past the cap so an over-size file is refused without
        // ever buffering the whole thing.
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else {
            throw FileTooLargeError(byteCount: nil)
        }
        return data
    }
}
