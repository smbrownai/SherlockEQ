//
//  TinnitusCheckInStoreTests.swift
//  SherlockEQTests
//
//  Daily annoyance-rating persistence: same-day replace (not merge), 0–10
//  clamping, retention pruning, disk round-trip, rating lookup, and
//  removeRecent — all against a per-test temp file so nothing touches the
//  real history.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct TinnitusCheckInStoreTests {

    private static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SherlockEQ-CheckInTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tinnitus-checkins.json", isDirectory: false)
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
    }

    @Test func recordThenLoadRoundTrips() {
        let url = Self.makeTempURL()
        let store = TinnitusCheckInStore(fileURL: url)
        store.record(annoyance: 6, on: day(-1))
        #expect(store.records.count == 1)
        #expect(store.records.first?.annoyance == 6)

        let reloaded = TinnitusCheckInStore(fileURL: url)
        reloaded.loadAll()
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records.first?.annoyance == 6)
    }

    @Test func missingFileLoadsEmptyWithoutError() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        store.loadAll()
        #expect(store.records.isEmpty)
        #expect(store.lastError == nil)
    }

    // Unlike dose peaks, a re-entry for the same day REPLACES (it's the user's
    // stated rating), including lowering it.
    @Test func sameDayReplacesRatingIncludingLower() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        store.record(annoyance: 8, on: day(-1))
        store.record(annoyance: 3, on: day(-1))
        #expect(store.records.count == 1)
        #expect(store.records.first?.annoyance == 3)
    }

    @Test func differentTimesSameDayCollapseToOneRecord() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        let base = Calendar.current.startOfDay(for: Date())
        store.record(annoyance: 4, on: base.addingTimeInterval(9 * 3600))
        store.record(annoyance: 7, on: base.addingTimeInterval(21 * 3600))
        #expect(store.records.count == 1)
        #expect(store.records.first?.annoyance == 7)
    }

    @Test func ratingClampsToZeroTen() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        store.record(annoyance: 42, on: day(-1))
        store.record(annoyance: -5, on: day(-2))
        #expect(store.rating(on: day(-1)) == 10)
        #expect(store.rating(on: day(-2)) == 0)
    }

    @Test func ratingLookupFindsTheDay() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        #expect(store.rating(on: day(0)) == nil)
        store.record(annoyance: 5, on: day(0))
        #expect(store.rating(on: day(0)) == 5)
        #expect(store.rating(on: day(-1)) == nil)
    }

    @Test func recordsStaySortedOldestFirst() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        store.record(annoyance: 2, on: day(-1))
        store.record(annoyance: 5, on: day(-5))
        store.record(annoyance: 4, on: day(-3))
        let starts = store.records.map(\.dayStart)
        #expect(starts == starts.sorted())
    }

    @Test func prunesBeyondRetentionWindow() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        for i in 0...TinnitusCheckInStore.retentionDays {
            store.record(annoyance: 1, on: day(-i))
        }
        #expect(store.records.count == TinnitusCheckInStore.retentionDays)
    }

    @Test func removeRecentDropsWindowKeepsOlder() {
        let store = TinnitusCheckInStore(fileURL: Self.makeTempURL())
        store.record(annoyance: 3, on: day(-1))
        store.record(annoyance: 4, on: day(-6))
        store.record(annoyance: 5, on: day(-10))
        store.removeRecent(days: 7)
        #expect(store.records.count == 1)
        #expect(store.records.first?.annoyance == 5)
    }

    @Test func savedFileHasOwnerOnlyPermissions() throws {
        let url = Self.makeTempURL()
        let store = TinnitusCheckInStore(fileURL: url)
        store.record(annoyance: 5, on: day(-1))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let posix = attrs[.posixPermissions] as? NSNumber
        #expect(posix?.intValue == 0o600)
    }
}
