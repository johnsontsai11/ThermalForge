//
//  ActiveProfileTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

/// Minimal unchecked box: each index is written by exactly one iteration.
final class UnsafeMutableTransferBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Active profile sidecar")
struct ActiveProfileTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-active-\(UUID().uuidString).json")
    }

    private var quiet: FanProfile {
        FanProfile(id: "smart-mini-quiet", name: "Smart (Mac mini, quiet)",
                   curve: .init(stopTemp: 45, startTemp: 60, ceilingTemp: 85,
                                maxRPMPercent: 1.0, curveShape: .easeIn,
                                sustainedTriggerSec: 6,
                                adaptive: .init(smoothingSec: 10, rateBoost: 0.1,
                                                useCalibration: false)))
    }

    @Test("A written record round-trips with the curve that was live")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try ActiveProfileRecord(profile: quiet).write(to: url)

        let found = ActiveProfileRecord.read(from: url, isAlive: { _ in true })
        let r = try #require(found.record)
        #expect(r.id == "smart-mini-quiet")
        #expect(r.name == "Smart (Mac mini, quiet)")
        #expect(r.curve.ceilingTemp == 85)
        #expect(r.curve.stopTemp == 45)
        #expect(r.curve.curveShape == .easeIn)
        #expect(r.curve.adaptive?.smoothingSec == 10)
    }

    @Test("A record whose writer has exited is unavailable, not returned as live")
    func deadWriterIsNotLive() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try ActiveProfileRecord(profile: quiet).write(to: url)

        let found = ActiveProfileRecord.read(from: url, isAlive: { _ in false })
        #expect(found.record == nil)
        // The note names the profile so a capture taken with the app down is still
        // interpretable, without claiming that profile was controlling the fan.
        let note = try #require(found.note)
        #expect(note.contains("app not running"))
        #expect(note.contains("Smart (Mac mini, quiet)"))
    }

    @Test("A missing sidecar is reported, not treated as an error")
    func missingSidecar() {
        let found = ActiveProfileRecord.read(from: tempURL(), isAlive: { _ in true })
        #expect(found.record == nil)
        #expect(found.note?.contains("no active-profile record") == true)
    }

    @Test("A corrupt sidecar is reported rather than crashing or silently attributing")
    func corruptSidecar() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        let found = ActiveProfileRecord.read(from: url, isAlive: { _ in true })
        #expect(found.record == nil)
        #expect(found.note?.contains("unreadable") == true)
    }

    @Test("Rewriting replaces the record, so the sidecar tracks the latest switch")
    func rewriteReplaces() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try ActiveProfileRecord(profile: quiet).write(to: url)
        try ActiveProfileRecord(profile: .silent).write(to: url)

        let r = try #require(ActiveProfileRecord.read(from: url, isAlive: { _ in true }).record)
        #expect(r.id == FanProfile.silent.id)
    }

    @Test("Records built concurrently all carry a valid timestamp (the shared formatter is safe)")
    func concurrentRecordCreationIsSafe() {
        // The ISO formatter is a shared static: it is never mutated after creation, so
        // concurrent formatting is safe. This guards that, since a per-call formatter
        // would have made the question moot.
        let profile = quiet
        let results = UnsafeMutableTransferBox([String?](repeating: nil, count: 200))
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            results.value[i] = ActiveProfileRecord(profile: profile).asOf
        }
        let parser = ISO8601DateFormatter()
        for stamp in results.value {
            let s = stamp ?? ""
            #expect(!s.isEmpty)
            #expect(parser.date(from: s) != nil, "unparseable timestamp: \(s)")
        }
    }

    @Test("The live process counts as alive, so a real app's record is honoured")
    func ownProcessIsAlive() {
        #expect(ActiveProfileRecord.processIsAlive(ProcessInfo.processInfo.processIdentifier))
    }
}
