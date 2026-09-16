//
//  MenuBarTemperatureTests.swift
//  ThermalForge
//

import Testing

@testable import ThermalForgeCore

@Suite("Menu bar temperature")
struct MenuBarTemperatureTests {

    /// Feeds `peaks` in order and returns every temperature the label was asked to show.
    private func shown(_ label: inout MenuBarTemperature, _ peaks: [Float]) -> [Float] {
        peaks.compactMap { label.add($0) }
    }

    @Test("The first reading is shown")
    func firstReading() {
        var label = MenuBarTemperature(samples: 10)
        #expect(label.add(55.4) == 55.4)
    }

    @Test("A Tp0W-style 55↔78°C alternation settles on its 10 s average and stops redrawing")
    func alternationSettles() {
        var label = MenuBarTemperature(samples: 10)
        let alternating = (0..<60).map { $0 % 2 == 0 ? Float(55) : Float(78) }
        _ = shown(&label, Array(alternating.prefix(10)))
        #expect(shown(&label, Array(alternating.dropFirst(10))) == []) // average holds at 66.5
    }

    @Test("A sustained rise walks the label up one degree per update")
    func sustainedRise() {
        var label = MenuBarTemperature(samples: 10)
        _ = shown(&label, Array(repeating: 60.5, count: 10))
        let rise = shown(&label, Array(repeating: 70.5, count: 10))
        #expect(rise.map { Int($0) } == [61, 62, 63, 64, 65, 66, 67, 68, 69, 70])
        #expect(rise.last == 70.5)
    }

    @Test("A change visible only in °F is still shown")
    func fahrenheitOnlyChange() {
        var label = MenuBarTemperature(samples: 1)
        #expect(label.add(50.0) == 50.0) // 50°C, 122°F
        #expect(label.add(50.6) == 50.6) // still 50°C, now 123°F
    }
}
