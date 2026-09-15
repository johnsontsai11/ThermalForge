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
}
