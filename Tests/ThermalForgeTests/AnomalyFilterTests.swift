//
//  AnomalyFilterTests.swift
//  ThermalForge
//

import Testing

@testable import ThermalForgeCore

@Suite("Anomaly log filter")
struct AnomalyFilterTests {

    @Test("Rolling median fills, then slides")
    func rollingMedian() {
        var median = RollingMedian(capacity: 3)
        #expect(median.add(5) == 5)
        #expect(median.add(1) == 3) // even count: mean of the middle two
        #expect(median.add(9) == 5)
        #expect(median.add(2) == 2) // 5 dropped: [1, 9, 2]
    }

    @Test("6-second median ignores a 2-second Tp0W blip")
    func ignoresShortBlip() {
        var median = RollingMedian(capacity: 60) // 6 s at 100 ms ticks
        for _ in 0..<60 { _ = median.add(51) }
        var filtered: Float = 0
        for _ in 0..<20 { filtered = median.add(78) } // 2 s blip, as measured on the Mac mini M4
        #expect(filtered == 51)
        for _ in 0..<20 { filtered = median.add(51) }
        #expect(filtered == 51)
    }

    @Test("6-second median keeps a real step at full size")
    func keepsRealStep() {
        var median = RollingMedian(capacity: 60)
        for _ in 0..<60 { _ = median.add(51) }
        var filtered: Float = 0
        for _ in 0..<31 { filtered = median.add(75) } // load that sticks past half the window
        #expect(filtered == 75)
    }

    // MARK: - Process history

    private static let second: UInt64 = 1_000_000_000

    @Test("Top processes by CPU share since the last sample, busiest first")
    func topProcessesByCPUShare() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([.init(pid: 10, name: "swift-frontend", cpuNs: 0),
                            .init(pid: 11, name: "yes", cpuNs: 5 * Self.second),
                            .init(pid: 12, name: "Finder", cpuNs: 0)], at: 0)
        // 2 s later: yes used a full core, swift-frontend half of one, Finder 0.05%.
        let history = tracker.update([.init(pid: 10, name: "swift-frontend", cpuNs: Self.second),
                                      .init(pid: 11, name: "yes", cpuNs: 7 * Self.second),
                                      .init(pid: 12, name: "Finder", cpuNs: 1_000_000)], at: 2 * Self.second)
        #expect(history == "yes(100.0%), swift-frontend(50.0%)")
    }

    @Test("No baseline yet reads unavailable, not idle")
    func firstSampleUnavailable() {
        var tracker = ProcessCPUTracker()
        #expect(tracker.update([.init(pid: 11, name: "yes", cpuNs: 5 * Self.second)], at: 0) == "unavailable")
    }

    @Test("Nothing above 0.1% reads idle")
    func quietSystemIdle() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([.init(pid: 12, name: "Finder", cpuNs: 0)], at: 0)
        #expect(tracker.update([.init(pid: 12, name: "Finder", cpuNs: 1_000_000)], at: 2 * Self.second) == "idle")
    }

    @Test("Keeps only the top 5")
    func topFiveOnly() {
        var tracker = ProcessCPUTracker()
        let pids: [Int32] = [1, 2, 3, 4, 5, 6]
        _ = tracker.update(pids.map { .init(pid: $0, name: "p\($0)", cpuNs: 0) }, at: 0)
        // pN used N × 10% of a core over 1 s.
        let history = tracker.update(pids.map { .init(pid: $0, name: "p\($0)", cpuNs: UInt64($0) * Self.second / 10) },
                                     at: Self.second)
        #expect(history == "p6(60.0%), p5(50.0%), p4(40.0%), p3(30.0%), p2(20.0%)")
    }

    @Test("A new or reused pid needs its own baseline")
    func newOrReusedPidSkipped() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([.init(pid: 20, name: "old", cpuNs: 9 * Self.second)], at: 0)
        // pid 20 exited and was reused (CPU time went backwards); pid 21 just started.
        let history = tracker.update([.init(pid: 20, name: "new", cpuNs: Self.second),
                                      .init(pid: 21, name: "fresh", cpuNs: Self.second)], at: Self.second)
        #expect(history == "idle")
    }
}
