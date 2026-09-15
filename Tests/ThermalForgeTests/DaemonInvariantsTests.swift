//
//  DaemonInvariantsTests.swift
//  ThermalForge
//
//  Phase 3 invariants, tested hardware-free via the extracted decision types:
//  the token-bucket rate limiter (burst / refill / ramp-never-trips / flood) and
//  the thermal-floor decision (engage only for a below-max hold while overheating,
//  restore only past the hysteresis point, thresholds mirrored from FanProfile).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Daemon invariants (Phase 3)")
struct DaemonInvariantsTests {

    // MARK: - Rate limiter

    @Test("burst up to capacity, then rate-limited, then refills at the rate")
    func rateLimiterBucket() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var rl = RateLimiter(capacity: 20, refillPerSecond: 10, now: t0)

        for _ in 0..<20 { let ok = rl.allow(now: t0); #expect(ok) }   // full burst
        let drained = rl.allow(now: t0); #expect(drained == false)   // no time elapsed

        // After 1s, ~10 tokens are back.
        let t1 = t0.addingTimeInterval(1.0)
        var allowed = 0
        for _ in 0..<20 { if rl.allow(now: t1) { allowed += 1 } }
        #expect(allowed == 10)
        let stillDenied = rl.allow(now: t1); #expect(stillDenied == false)
    }

    @Test("a steady ~10/s ramp (the pump's coalesced rate) never trips")
    func rateLimiterRampNeverTrips() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        var rl = RateLimiter(capacity: 20, refillPerSecond: 10, now: t)
        for _ in 0..<100 {                 // 10s of 10/s, spaced 100ms
            let ok = rl.allow(now: t)
            #expect(ok)
            t = t.addingTimeInterval(0.1)
        }
    }

    @Test("an instantaneous flood is capped at the burst size")
    func rateLimiterFloodThrottled() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        var rl = RateLimiter(capacity: 20, refillPerSecond: 10, now: t)
        var allowed = 0
        for _ in 0..<1000 { if rl.allow(now: t) { allowed += 1 } }
        #expect(allowed == 20)
    }

    // MARK: - Thermal floor decision

    @Test("engages only when overheating AND a below-max hold is active")
    func thermalFloorEngage() {
        let floor = ThermalFloor()   // 95 / 90 from FanProfile
        #expect(floor.evaluate(temp: 95, sustained: true, holdCommand: "set 2000", suspended: false) == .engage)
        #expect(floor.evaluate(temp: 96, sustained: true, holdCommand: "setfan 1 1500", suspended: false) == .engage)
        // No hold (auto) → Apple's auto + client monitor own it.
        #expect(floor.evaluate(temp: 99, sustained: true, holdCommand: nil, suspended: false) == .none)
        // Already max → nothing to override.
        #expect(floor.evaluate(temp: 99, sustained: true, holdCommand: "max", suspended: false) == .none)
        // Below threshold → none.
        #expect(floor.evaluate(temp: 94.9, sustained: true, holdCommand: "set 2000", suspended: false) == .none)
    }

    @Test("a brief jump past the threshold doesn't engage")
    func thermalFloorNeedsSustainedHeat() {
        let floor = ThermalFloor()
        #expect(floor.evaluate(temp: 96, sustained: false, holdCommand: "set 2000", suspended: false) == .none)
    }

    @Test("restores only after cooling past the hysteresis point")
    func thermalFloorRestoreHysteresis() {
        let floor = ThermalFloor()
        // Still in the 90–95 band → keep max.
        #expect(floor.evaluate(temp: 95, sustained: true, holdCommand: "set 2000", suspended: true) == .none)
        #expect(floor.evaluate(temp: 91, sustained: false, holdCommand: "set 2000", suspended: true) == .none)
        // Cooled below 90 → restore.
        #expect(floor.evaluate(temp: 89.9, sustained: false, holdCommand: "set 2000", suspended: true) == .restore)
        // Restore fires even with the hold cleared (dead app) — daemon then goes to auto.
        #expect(floor.evaluate(temp: 80, sustained: false, holdCommand: nil, suspended: true) == .restore)
    }

    @Test("an implausible reading never engages or releases the override")
    func thermalFloorIgnoresImplausibleReading() {
        let floor = ThermalFloor()
        // 7.3°C just after wake would otherwise read as "cooled" and drop fans off max.
        #expect(floor.evaluate(temp: 7.3, sustained: false, holdCommand: "set 2000", suspended: true) == .none)
        #expect(floor.evaluate(temp: 7.3, sustained: false, holdCommand: nil, suspended: true) == .none)
        #expect(floor.evaluate(temp: 7.3, sustained: false, holdCommand: "set 2000", suspended: false) == .none)
    }

    // MARK: - Sustained heat

    /// Feed (hot, seconds-from-start) readings through one SustainedHeat; return each verdict.
    private func sustainedVerdicts(_ readings: [(hot: Bool, at: TimeInterval)]) -> [Bool] {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var heat = SustainedHeat()
        return readings.map { heat.update(hot: $0.hot, now: t0.addingTimeInterval($0.at)) }
    }

    @Test("hot only after 3 s straight at the sensor's ~1 s update rate")
    func sustainedHeatAfterThreeSeconds() {
        let verdicts = sustainedVerdicts([(true, 0), (true, 1), (true, 2), (true, 3)])
        #expect(verdicts == [false, false, false, true])
    }

    @Test("the measured Tp0W jumps (1–2 s, 1 s apart) never count as sustained")
    func sustainedHeatIgnoresJumps() {
        // 2 s jump, 1 s cool, 2 s jump, then cool — never 3 s straight.
        let verdicts = sustainedVerdicts([(true, 0), (true, 1), (false, 2), (true, 3), (true, 4), (false, 5)])
        #expect(!verdicts.contains(true))
    }

    @Test("a gap in readings restarts the count")
    func sustainedHeatRestartsAfterGap() {
        // Hot, then no readings for 10 s (daemon had no hold to protect): not 10 s of heat.
        let verdicts = sustainedVerdicts([(true, 0), (true, 10), (true, 12), (true, 13)])
        #expect(verdicts == [false, false, false, true])
    }

    @Test("thresholds mirror FanProfile, not hardcoded numbers")
    func thermalFloorThresholdsMirrorProfile() {
        let floor = ThermalFloor()
        #expect(floor.threshold == FanProfile.safetyTempThreshold)
        #expect(floor.clearBelow == FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees)
    }
}
