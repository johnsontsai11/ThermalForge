//
//  CalibrationTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Calibration")
struct CalibrationTests {

    // MARK: - Invoking user

    @Test("Under sudo, calibration belongs to the user who ran sudo")
    func invokingUserUnderSudo() {
        #expect(CalibrationData.invokingUserID(euid: 0, environment: ["SUDO_UID": "501"]) == 501)
    }

    @Test("No sudo user: not root, a root shell, or a bad SUDO_UID")
    func noInvokingUser() {
        #expect(CalibrationData.invokingUserID(euid: 501, environment: ["SUDO_UID": "501"]) == nil)
        #expect(CalibrationData.invokingUserID(euid: 0, environment: [:]) == nil)
        #expect(CalibrationData.invokingUserID(euid: 0, environment: ["SUDO_UID": "0"]) == nil)
        #expect(CalibrationData.invokingUserID(euid: 0, environment: ["SUDO_UID": "abc"]) == nil)
    }

    // MARK: - Sweep readings

    /// Feed raw readings through one filter; return each (filtered, safety) result.
    private func readings(_ raw: [Float]) -> [(filtered: Float?, safety: Bool)] {
        var filter = CalibrationReadings()
        return raw.map { filter.add($0) }
    }

    @Test("No filtered reading until the 10 s median window is full")
    func filteredWaitsForFullWindow() {
        // A Tp0W jump as the very first reading can't trip the 84°C ceiling.
        let results = readings([87, 60, 60, 60, 60])
        #expect(results.prefix(4).allSatisfy { $0.filtered == nil })
        #expect(results[4].filtered == 60)
    }

    @Test("A 1- or 2-reading Tp0W jump doesn't move the filtered temperature")
    func jumpIgnored() {
        let results = readings([60, 60, 60, 60, 60, 87, 87, 60])
        #expect(results.compactMap(\.filtered).allSatisfy { $0 == 60 })
    }

    @Test("A real step shows up once it holds for 3 readings")
    func realStepKept() {
        let results = readings([60, 60, 60, 60, 60, 80, 80, 80])
        #expect(results.last?.filtered == 80)
    }

    @Test("Safety needs 2 raw readings in a row at 90°C or more")
    func safetyNeedsTwoReadings() {
        #expect(readings([60, 91]).map(\.safety) == [false, false])
        #expect(readings([60, 91, 60, 91]).map(\.safety) == [false, false, false, false])
        #expect(readings([60, 91, 92]).map(\.safety) == [false, false, true])
    }

    // MARK: - Heating rate (Phase 1)

    /// 11 readings 1 s apart, rising at `rate` °C/s from 55°C.
    private func rising(_ rate: Float) -> [(at: TimeInterval, temp: Float)] {
        (0...10).map { (TimeInterval($0), 55 + rate * Float($0)) }
    }

    @Test("Heating rate of a steady rise")
    func heatingRateSteady() {
        #expect(CalibrationRunner.heatingRate(rising(1.0)) == 1.0)
    }

    @Test("Tp0W jumps at either end don't change the heating rate")
    func heatingRateIgnoresJumps() {
        var samples = rising(1.0)
        samples[0].temp += 27              // jump on the first reading
        samples[8].temp += 27              // 2-reading jump near the end
        samples[9].temp += 27
        #expect(CalibrationRunner.heatingRate(samples) == 1.0)
    }

    @Test("Flat temperature with a jump reads as no heating")
    func heatingRateFlat() {
        var samples = rising(0)
        samples[10].temp += 27
        #expect(CalibrationRunner.heatingRate(samples) == 0)
    }

    @Test("Unreadable (0) readings are dropped; fewer than 2 left is no rate")
    func heatingRateUnreadable() {
        #expect(CalibrationRunner.heatingRate([(0, 0), (1, 56), (2, 0)]) == nil)
        #expect(CalibrationRunner.heatingRate([(0, 55), (1, 0), (2, 57)]) == 1.0)
    }

    // MARK: - Cooldown

    /// Feed (temp, seconds) readings until the wait ends; return the outcome and when.
    private func cooldown(_ samples: [(temp: Float, at: TimeInterval)]) -> (outcome: CooldownWait.Outcome, at: TimeInterval)? {
        var wait = CooldownWait(threshold: 45)
        for sample in samples {
            if let outcome = wait.add(temp: sample.temp, at: sample.at) { return (outcome, sample.at) }
        }
        return nil
    }

    @Test("Stops as soon as it's below the target")
    func cooledBelowTarget() {
        let result = cooldown([(50, 0), (46, 2), (44.5, 4)])
        #expect(result?.outcome == .cooled(temp: 44.5))
        #expect(result?.at == 4)
    }

    @Test("Mac mini idle: stops once no new 0.5°C low for 30 s, jumps included")
    func stoppedFalling() {
        // Falls 70 → 56 in 14 s, then idles at 56 with a Tp0W jump every few seconds.
        var samples: [(temp: Float, at: TimeInterval)] = (0...7).map { (70 - 2 * Float($0), TimeInterval(2 * $0)) }
        samples += (8...40).map { i in (i % 3 == 0 ? 83 : 56, TimeInterval(2 * i)) }
        let result = cooldown(samples)
        #expect(result?.outcome == .stoppedFalling(lowest: 56))
        #expect(result?.at == 44)   // last new low at 14 s + 30 s
    }

    @Test("A slow but steady fall keeps waiting, up to the 5 min cap")
    func timedOutWhileFalling() {
        // 0.6°C every 10 s: always a fresh low, never below 45.
        let samples: [(temp: Float, at: TimeInterval)] = (0...160).map { (80 - 0.6 * Float($0 / 5), TimeInterval(2 * $0)) }
        let result = cooldown(samples)
        #expect(result?.at == 300)
        if case .timedOut = result?.outcome {} else { Issue.record("expected timedOut, got \(String(describing: result?.outcome))") }
    }

    @Test("Unreadable temperatures don't end the wait early")
    func unreadableIgnored() {
        #expect(cooldown([(0, 0), (0, 2), (0, 40)])?.at == nil)
    }
}
