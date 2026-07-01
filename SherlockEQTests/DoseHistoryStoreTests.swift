//
//  DoseHistoryStoreTests.swift
//  SherlockEQTests
//
//  Daily dose-peak persistence: upsert/merge by day, the peak>0 filter,
//  retention pruning, round-trip through disk, and removeRecent — all driven
//  against a per-test temp file so nothing touches the real history.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct DoseHistoryStoreTests {

    private static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SherlockEQ-DoseHistoryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dose-history.json", isDirectory: false)
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
    }

    // MARK: - Basic record + load

    @Test func recordThenLoadRoundTrips() {
        let url = Self.makeTempURL()
        let store = DoseHistoryStore(fileURL: url)
        store.record(dayStart: day(-1), peakDose: 0.5)
        #expect(store.records.count == 1)
        #expect(store.records.first?.peakDose == 0.5)

        let reloaded = DoseHistoryStore(fileURL: url)
        reloaded.loadAll()
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records.first?.peakDose == 0.5)
    }

    @Test func savedFileHasOwnerOnlyPermissions() throws {
        let url = Self.makeTempURL()
        let store = DoseHistoryStore(fileURL: url)
        store.record(dayStart: day(-1), peakDose: 0.5)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let posix = attrs[.posixPermissions] as? NSNumber
        #expect(posix?.intValue == 0o600)
    }

    @Test func directoryIsExcludedFromBackup() throws {
        let url = Self.makeTempURL()
        let store = DoseHistoryStore(fileURL: url)
        store.record(dayStart: day(-1), peakDose: 0.5)

        let directory = url.deletingLastPathComponent()
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func missingFileLoadsEmptyWithoutError() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.loadAll()
        #expect(store.records.isEmpty)
        #expect(store.lastError == nil)
    }

    // MARK: - Day normalisation + merge

    @Test func sameDayKeepsHigherPeak() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.record(dayStart: day(-1), peakDose: 0.4)
        store.record(dayStart: day(-1), peakDose: 0.7)
        #expect(store.records.count == 1)
        #expect(store.records.first?.peakDose == 0.7)
    }

    @Test func sameDayLowerPeakDoesNotOverwrite() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.record(dayStart: day(-1), peakDose: 0.7)
        store.record(dayStart: day(-1), peakDose: 0.2)
        #expect(store.records.count == 1)
        #expect(store.records.first?.peakDose == 0.7)
    }

    @Test func differentTimesSameDayCollapseToOneRecord() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        let base = Calendar.current.startOfDay(for: Date())
        let morning = base.addingTimeInterval(9 * 3600)
        let evening = base.addingTimeInterval(21 * 3600)
        store.record(dayStart: morning, peakDose: 0.3)
        store.record(dayStart: evening, peakDose: 0.6)
        #expect(store.records.count == 1)
        #expect(store.records.first?.peakDose == 0.6)
    }

    // MARK: - Filtering + clamping

    @Test func zeroPeakIsNotStored() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.record(dayStart: day(-1), peakDose: 0)
        #expect(store.records.isEmpty)
    }

    @Test func peakClampsToOne() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.record(dayStart: day(-1), peakDose: 1.8)
        #expect(store.records.first?.peakDose == 1.0)
    }

    // MARK: - Retention + ordering

    @Test func recordsStaySortedOldestFirst() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.record(dayStart: day(-1), peakDose: 0.2)
        store.record(dayStart: day(-5), peakDose: 0.5)
        store.record(dayStart: day(-3), peakDose: 0.4)
        let starts = store.records.map(\.dayStart)
        #expect(starts == starts.sorted())
    }

    @Test func prunesBeyondRetentionWindow() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        // One more than retention; oldest should be dropped.
        for i in 0...DoseHistoryStore.retentionDays {
            store.record(dayStart: day(-i), peakDose: 0.1)
        }
        #expect(store.records.count == DoseHistoryStore.retentionDays)
        // The oldest day (-retentionDays) is gone; -(retentionDays-1) survives.
        let oldest = Calendar.current.startOfDay(for: day(-(DoseHistoryStore.retentionDays - 1)))
        #expect(store.records.first?.dayStart == oldest)
    }

    // MARK: - removeRecent

    @Test func removeRecentDropsWindowKeepsOlder() {
        let store = DoseHistoryStore(fileURL: Self.makeTempURL())
        store.record(dayStart: day(-1), peakDose: 0.3)   // within last 7
        store.record(dayStart: day(-6), peakDose: 0.4)   // within last 7
        store.record(dayStart: day(-10), peakDose: 0.5)  // older
        store.removeRecent(days: 7)
        #expect(store.records.count == 1)
        #expect(store.records.first?.peakDose == 0.5)
    }

    // MARK: - Severity derivation

    @Test func severityMatchesThresholds() {
        #expect(DailyDoseRecord(dayStart: day(0), peakDose: 0.5).severity == .safe)
        #expect(DailyDoseRecord(dayStart: day(0), peakDose: 0.8).severity == .amber)
        #expect(DailyDoseRecord(dayStart: day(0), peakDose: 1.0).severity == .red)
    }
}
