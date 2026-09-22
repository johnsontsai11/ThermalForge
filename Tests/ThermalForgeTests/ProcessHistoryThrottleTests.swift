//
//  ProcessHistoryThrottleTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Process history throttle")
struct ProcessHistoryThrottleTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("The first spike always dumps — there is nothing to deduplicate yet")
    func firstSpikeDumps() {
        var t = ProcessHistoryThrottle(cooldown: 300)
        #expect(t.record(at: t0) == .dump(suppressedSinceLastDump: 0))
    }

    @Test("Spikes inside the cooldown are suppressed and counted")
    func suppressedInsideCooldown() {
        var t = ProcessHistoryThrottle(cooldown: 300)
        _ = t.record(at: t0)
        #expect(t.record(at: t0.addingTimeInterval(2)) == .suppress)
        #expect(t.record(at: t0.addingTimeInterval(120)) == .suppress)
        #expect(t.record(at: t0.addingTimeInterval(299)) == .suppress)
    }

    @Test("The next dump after the cooldown reports how many spikes were hidden")
    func dumpReportsSuppressedCount() {
        var t = ProcessHistoryThrottle(cooldown: 300)
        _ = t.record(at: t0)
        for i in 1...9 { _ = t.record(at: t0.addingTimeInterval(Double(i) * 2)) }
        // Nine spikes hidden, then one past the cooldown: the dump accounts for them,
        // so a quiet stretch in the log is never mistaken for a quiet machine.
        #expect(t.record(at: t0.addingTimeInterval(300)) == .dump(suppressedSinceLastDump: 9))
    }

    @Test("The suppressed counter resets after each dump")
    func counterResets() {
        var t = ProcessHistoryThrottle(cooldown: 10)
        _ = t.record(at: t0)
        _ = t.record(at: t0.addingTimeInterval(1))
        #expect(t.record(at: t0.addingTimeInterval(10)) == .dump(suppressedSinceLastDump: 1))
        #expect(t.record(at: t0.addingTimeInterval(20)) == .dump(suppressedSinceLastDump: 0))
    }

    @Test("A zero cooldown keeps the old dump-every-spike behaviour")
    func zeroCooldownAlwaysDumps() {
        var t = ProcessHistoryThrottle(cooldown: 0)
        #expect(t.record(at: t0) == .dump(suppressedSinceLastDump: 0))
        #expect(t.record(at: t0.addingTimeInterval(0.1)) == .dump(suppressedSinceLastDump: 0))
    }

    @Test("Clock going backwards does not wedge the throttle permanently")
    func backwardsClockRecovers() {
        var t = ProcessHistoryThrottle(cooldown: 300)
        _ = t.record(at: t0)
        // A backwards jump must not be read as "cooldown elapsed" nor strand the
        // throttle; the next forward reading past the cooldown dumps normally.
        #expect(t.record(at: t0.addingTimeInterval(-600)) == .suppress)
        #expect(t.record(at: t0.addingTimeInterval(300)) == .dump(suppressedSinceLastDump: 1))
    }
}
