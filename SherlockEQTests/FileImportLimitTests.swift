//
//  FileImportLimitTests.swift
//  SherlockEQTests
//
//  The 8 MB ceiling on user-picked imports (audit F-1). Files are written
//  to a per-test temporary location so nothing touches real user data.
//

import Testing
import Foundation
@testable import SherlockEQ

struct FileImportLimitTests {

    // MARK: - Helpers

    /// Write `byteCount` bytes to a fresh temp file and return its URL.
    private func makeFile(byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fil-\(UUID().uuidString).bin")
        try Data(count: byteCount).write(to: url)
        return url
    }

    private func makeTextFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fil-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: - Under / at / over the cap

    @Test func smallFilePasses() throws {
        let url = try makeFile(byteCount: 1024)
        defer { remove(url) }
        let data = try FileImportLimit.data(at: url)
        #expect(data.count == 1024)
    }

    @Test func fileAtExactlyTheCapPasses() throws {
        let url = try makeFile(byteCount: FileImportLimit.maxBytes)
        defer { remove(url) }
        let data = try FileImportLimit.data(at: url)
        #expect(data.count == FileImportLimit.maxBytes)
    }

    @Test func fileOneByteOverTheCapThrows() throws {
        let over = FileImportLimit.maxBytes + 1
        let url = try makeFile(byteCount: over)
        defer { remove(url) }

        #expect(throws: FileImportLimit.FileTooLargeError.self) {
            try FileImportLimit.check(url)
        }
        #expect(throws: FileImportLimit.FileTooLargeError.self) {
            _ = try FileImportLimit.data(at: url)
        }
    }

    @Test func tooLargeErrorCarriesReportedSizeAndDescribesTheLimit() throws {
        let over = FileImportLimit.maxBytes + 1
        let url = try makeFile(byteCount: over)
        defer { remove(url) }

        do {
            try FileImportLimit.check(url)
            Issue.record("expected FileTooLargeError")
        } catch let error as FileImportLimit.FileTooLargeError {
            #expect(error.byteCount == over)
            let description = try #require(error.errorDescription)
            #expect(description.contains("too large"))
        }
    }

    // MARK: - String path

    @Test func boundedStringReturnsContentsForASmallFile() throws {
        let url = try makeTextFile("GraphicEQ: 31 -1.0; 63 -0.5")
        defer { remove(url) }
        let text = try FileImportLimit.string(at: url)
        #expect(text.contains("GraphicEQ"))
    }

    @Test func boundedStringThrowsForAnOversizedFile() throws {
        let url = try makeFile(byteCount: FileImportLimit.maxBytes + 1)
        defer { remove(url) }
        #expect(throws: FileImportLimit.FileTooLargeError.self) {
            _ = try FileImportLimit.string(at: url)
        }
    }

    // MARK: - O_NOFOLLOW path (audit I-1)

    @Test func noFollowReadsARegularFile() throws {
        let url = try makeTextFile("{\"name\":\"ok\"}")
        defer { remove(url) }
        let data = try FileImportLimit.dataNoFollow(at: url)
        #expect(String(data: data, encoding: .utf8) == "{\"name\":\"ok\"}")
    }

    @Test func noFollowRefusesASymlinkAtTheFinalComponent() throws {
        let target = try makeTextFile("{\"secret\":true}")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fil-link-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { remove(link); remove(target) }

        // Following the link would read the target; NOFOLLOW must refuse it.
        #expect(throws: FileImportLimit.SymlinkRefusedError.self) {
            _ = try FileImportLimit.dataNoFollow(at: link)
        }
    }

    @Test func noFollowStillEnforcesTheCap() throws {
        let url = try makeFile(byteCount: FileImportLimit.maxBytes + 1)
        defer { remove(url) }
        #expect(throws: FileImportLimit.FileTooLargeError.self) {
            _ = try FileImportLimit.dataNoFollow(at: url)
        }
    }
}
