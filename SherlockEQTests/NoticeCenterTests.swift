//
//  NoticeCenterTests.swift
//  SherlockEQTests
//
//  The banner must FOLLOW the store's error state, both ways: a failed
//  persistence op raises it, and a later successful op clears it — errors
//  have no auto-dismiss, so before audit fix CX-04 a single failed save
//  left a stale "Save failed" banner up forever (`compactMap { $0 }`
//  dropped the recovering nil). The clear must also be surgical: only the
//  store's own banner, never an unrelated notice that replaced it.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct NoticeCenterTests {

    /// A store whose "directory" is an existing regular FILE: `save()` still
    /// succeeds in memory (ensureDirectory sees the path exists and only
    /// attempts a chmod), but the deferred disk write fails deterministically
    /// with not-a-directory — exactly the async-failure shape CX-04 is about.
    private static func makeFailingStore() throws -> (store: ProfileStore, cleanup: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoticeCenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bogusDir = parent.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: bogusDir.path, contents: Data("x".utf8))
        return (ProfileStore(directory: bogusDir), parent)
    }

    @Test func storeErrorBannerShowsThenClearsOnRecovery() async throws {
        let (store, cleanup) = try Self.makeFailingStore()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let notices = NoticeCenter()
        notices.bind(to: store)

        let p = HearingProfile.makeDefault(name: "Doomed write")
        try store.save(p)            // in-memory apply OK; disk write deferred
        store.flushPendingWrites()   // deferred write fails → lastError set
        try await Task.sleep(for: .milliseconds(50))   // let the sink's Task run
        #expect(notices.userVisibleNotice != nil, "failed write should raise the banner")
        #expect(notices.userVisibleNotice?.severity == .error)

        // Recovery: the next successful op publishes lastError = nil via
        // tracking(); the banner must follow (errors never auto-dismiss).
        try store.save(p)
        try await Task.sleep(for: .milliseconds(50))
        #expect(notices.userVisibleNotice == nil, "banner must clear when the error clears")
    }

    @Test func recoveryDoesNotDismissUnrelatedNotices() async throws {
        let (store, cleanup) = try Self.makeFailingStore()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let notices = NoticeCenter()
        notices.bind(to: store)

        let p = HearingProfile.makeDefault(name: "Doomed write")
        try store.save(p)
        store.flushPendingWrites()
        try await Task.sleep(for: .milliseconds(50))
        #expect(notices.userVisibleNotice != nil)

        // A different source replaces the banner (e.g. a tap-permission
        // error). The store recovering must NOT yank this one down.
        let unrelated = TransientNotice(severity: .error, message: "Unrelated failure")
        notices.showNotice(unrelated)

        try store.save(p)   // store recovers → publishes nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(notices.userVisibleNotice?.id == unrelated.id,
                "recovery must not stomp an unrelated banner")
    }

    /// The user dismissing the store's banner and the store later recovering
    /// must not conjure anything back or crash on the stale id.
    @Test func recoveryAfterManualDismissIsANoOp() async throws {
        let (store, cleanup) = try Self.makeFailingStore()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let notices = NoticeCenter()
        notices.bind(to: store)

        let p = HearingProfile.makeDefault(name: "Doomed write")
        try store.save(p)
        store.flushPendingWrites()
        try await Task.sleep(for: .milliseconds(50))
        #expect(notices.userVisibleNotice != nil)

        notices.dismissNotice()
        try store.save(p)
        try await Task.sleep(for: .milliseconds(50))
        #expect(notices.userVisibleNotice == nil)
    }
}
