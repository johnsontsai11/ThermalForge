//
//  FanRampTests.swift
//  ThermalForge
//

import Testing

@testable import ThermalForgeCore

@Suite("Fan ramp")
struct FanRampTests {

    // Mac mini M4 fan (1,000–4,900 RPM) at a 200 ms tick: Smart's 0.05/s up, 0.025/s down.
    private let minRPM: Float = 1000
    private let maxRPM: Float = 4900
    private let up: Float = 0.01
    private let down: Float = 0.005
    private var floorPercent: Float { minRPM / maxRPM }

    /// Steps `ticks` times toward `target`, returning every RPM the ramp asked to send.
    private func run(_ ramp: inout FanRamp, toward target: Float, ticks: Int) -> [Float] {
        (0..<ticks).compactMap { _ in
            ramp.step(toward: target, up: up, down: down, instant: false, minRPM: minRPM, maxRPM: maxRPM)
        }
    }

    @Test("Ramping below the fan's minimum sends the minimum RPM once")
    func belowFloorSendsOnce() {
        var ramp = FanRamp()
        // Smoothed temp crosses the start threshold: up to the floor, down toward 0, up again.
        #expect(run(&ramp, toward: floorPercent, ticks: 30) == [1000])
        #expect(run(&ramp, toward: 0, ticks: 50) == [])
        #expect(run(&ramp, toward: floorPercent, ticks: 30) == [])
    }

    @Test("Above the minimum, each new RPM is sent")
    func aboveFloorSendsEachStep() {
        var ramp = FanRamp()
        ramp.reset(to: 0.5)
        let sent = run(&ramp, toward: 1, ticks: 3)
        #expect(sent.count == 3)
        #expect(abs(sent[0] - 2499) < 0.5) // 0.51 × 4,900
        #expect(abs(sent[2] - 2597) < 0.5) // 0.53 × 4,900
    }

    @Test("Descending onto the minimum sends it, then stays quiet")
    func descendOntoFloor() {
        var ramp = FanRamp()
        ramp.reset(to: 0.212) // 1,039 RPM
        let sent = run(&ramp, toward: 0, ticks: 3)
        #expect(sent.count == 2)
        #expect(sent.first == 1014) // 0.207 × 4,900 = 1,014.3, sent as whole RPM
        #expect(sent.last == 1000) // floored; the third tick sends nothing
    }

    @Test("After a reset, the next step sends again")
    func resetSendsAgain() {
        var ramp = FanRamp()
        #expect(run(&ramp, toward: floorPercent, ticks: 30) == [1000])
        ramp.reset(to: 0) // fans handed back to macOS
        #expect(run(&ramp, toward: floorPercent, ticks: 1) == [1000])
    }
}
