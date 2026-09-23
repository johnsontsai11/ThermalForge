//
//  AdaptiveProfileTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Adaptive profiles")
struct AdaptiveProfileTests {

    // MARK: - Built-in Smart is unchanged

    /// Smart's target math before it was driven by profile settings (hard-coded 53/85°C,
    /// S-curve, 0.2 boost uncalibrated, 0.15 × (1 + urgency) boost calibrated, 100% cap).
    private func originalSmartTarget(temp: Float, rate: Float, calibration: CalibrationData?) -> Float {
        let floor: Float = 53, ceiling: Float = 85
        var target: Float
        if let cal = calibration, let calPct = cal.fanPercentForTemp(temp) {
            target = calPct
            if rate > 0 {
                let urgency = min(max((temp - floor) / (ceiling - floor), 0), 1)
                target = min(target + rate * 0.15 * (1 + urgency), 1.0)
            }
        } else {
            let position = min(max((temp - floor) / (ceiling - floor), 0), 1)
            target = position * position * (3 - 2 * position)
            if rate > 0 { target = min(target + rate * 0.2, 1.0) }
        }
        if temp > ceiling { target = 1.0 }
        return min(max(target, 0), 1.0)
    }

    private let sampleCalibration = CalibrationData(
        machine: "Test", fans: 1, maxRPM: 4900, minRPM: 1000, calibratedAt: "2026-09-15T00:00:00Z",
        measurements: [
            .init(targetTemp: 60, holdingRPMPercent: 0.30),
            .init(targetTemp: 70, holdingRPMPercent: 0.50),
            .init(targetTemp: 80, holdingRPMPercent: 0.90),
        ]
    )

    @Test("Built-in Smart keeps its original settings")
    func builtInSmartSettings() {
        let curve = FanProfile.smart.curve
        #expect(curve.stopTemp == 50)
        #expect(curve.startTemp == 53)
        #expect(curve.ceilingTemp == 85)
        #expect(curve.maxRPMPercent == 1.0)
        #expect(curve.curveShape == .sCurve)
        #expect(curve.adaptive == FanProfile.Curve.Adaptive(smoothingSec: 0, rateBoost: 0.2, useCalibration: true))
    }

    @Test("Built-in Smart target matches the original formula, uncalibrated and calibrated")
    func builtInSmartMatchesOriginal() {
        let curve = FanProfile.smart.curve
        for cal in [nil, sampleCalibration] {
            for rate: Float in [-1, 0, 0.5, 3.8] {
                for temp in stride(from: Float(45), through: 92, by: 0.5) {
                    let expected = originalSmartTarget(temp: temp, rate: rate, calibration: cal)
                    let actual = curve.adaptiveTargetPercent(at: temp, rate: rate, calibration: cal)
                    #expect(abs(actual - expected) < 0.0001, "temp \(temp) rate \(rate) calibrated \(cal != nil)")
                }
            }
        }
    }

    // MARK: - Settings

    private func adaptiveCurve(cap: Float = 1.0, boost: Float, useCalibration: Bool) -> FanProfile.Curve {
        FanProfile.Curve(stopTemp: 50, startTemp: 53, ceilingTemp: 85, maxRPMPercent: cap,
                         curveShape: .sCurve, rampUpPerSec: 0.05, rampDownPerSec: 0.025,
                         sustainedTriggerSec: 6,
                         adaptive: .init(smoothingSec: 10, rateBoost: boost, useCalibration: useCalibration))
    }

    @Test("Boost strength scales the rising-temperature boost")
    func boostStrength() {
        let curve = adaptiveCurve(boost: 0.1, useCalibration: false)
        let base = curve.adaptiveTargetPercent(at: 60, rate: 0, calibration: nil)
        let rising = curve.adaptiveTargetPercent(at: 60, rate: 2, calibration: nil)
        #expect(abs((rising - base) - 0.2) < 0.0001)
        // Falling temperatures never boost
        #expect(curve.adaptiveTargetPercent(at: 60, rate: -2, calibration: nil) == base)
    }

    @Test("useCalibration false ignores the calibration table")
    func calibrationOff() {
        let off = adaptiveCurve(boost: 0.1, useCalibration: false)
        let on = adaptiveCurve(boost: 0.1, useCalibration: true)
        let sCurveAt70 = CurveShape.sCurve.apply((70 - 53) / 32)
        #expect(abs(off.adaptiveTargetPercent(at: 70, rate: 0, calibration: sampleCalibration) - sCurveAt70) < 0.0001)
        #expect(abs(on.adaptiveTargetPercent(at: 70, rate: 0, calibration: sampleCalibration) - 0.50) < 0.0001)
    }

    @Test("Target never exceeds the cap, including above the ceiling and with boost")
    func capRespected() {
        let curve = adaptiveCurve(cap: 0.7, boost: 1.0, useCalibration: false)
        #expect(curve.adaptiveTargetPercent(at: 90, rate: 0, calibration: nil) == 0.7)
        #expect(curve.adaptiveTargetPercent(at: 70, rate: 5, calibration: nil) == 0.7)
    }

    // MARK: - Smoothing

    @Test("Rolling average fills, then slides")
    func rollingAverage() {
        var avg = RollingAverage(capacity: 3)
        #expect(avg.add(1) == 1)
        #expect(avg.add(2) == 1.5)
        #expect(avg.add(3) == 2)
        #expect(avg.add(10) == 5) // (2 + 3 + 10) / 3
    }

    @Test("10-second window damps a 2-second spike")
    func spikeDamping() {
        var avg = RollingAverage(capacity: 100) // 10 s at 100 ms ticks
        for _ in 0..<100 { _ = avg.add(53) }
        var smoothed: Float = 0
        for _ in 0..<20 { smoothed = avg.add(76) } // 2 s spike
        #expect(abs(smoothed - 57.6) < 0.01) // 53 + 23 × 20/100
    }

    // MARK: - Saved profiles

    /// A fresh temp directory per test. Swift Testing builds a new suite instance for every
    /// test and runs them in parallel, so pointing at the user's real profile folder let
    /// fixtures from one test show up in another's scan — and logged every fixture's decode
    /// failure to the user's real ~/Library/Logs/ThermalForge file.
    private let profilesDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ThermalForgeTests-\(UUID().uuidString)", isDirectory: true)

    private func profile(id: String, stop: Float = 50, start: Float = 53, smoothing: Float = 10,
                         boost: Float = 0.1) -> FanProfile {
        FanProfile(id: id, name: id, curve: .init(
            stopTemp: stop, startTemp: start, ceilingTemp: 85, maxRPMPercent: 1.0, curveShape: .sCurve,
            rampUpPerSec: 0.05, rampDownPerSec: 0.025, sustainedTriggerSec: 6,
            adaptive: .init(smoothingSec: smoothing, rateBoost: boost, useCalibration: false)))
    }

    @Test("Validation accepts a Smart-style profile and rejects nonsensical ones")
    func validation() {
        #expect(profile(id: "test_ok").validationError == nil) // 3°C stop–start gap is allowed
        #expect(profile(id: "smart").validationError != nil)
        #expect(profile(id: "test_bad", stop: 60, start: 53).validationError != nil)
        #expect(profile(id: "test_bad", smoothing: 61).validationError != nil)
        #expect(profile(id: "test_bad", boost: 1.5).validationError != nil)
    }

    @Test("Saved custom profiles load and resolve; invalid files are skipped")
    func loadAndResolve() throws {
        let good = profile(id: "test_adaptive_good")
        let bad = profile(id: "test_adaptive_bad", stop: 60, start: 53)
        try good.save(in: profilesDir)
        try bad.save(in: profilesDir)
        defer { try? FileManager.default.removeItem(at: profilesDir) }

        let loaded = FanProfile.loadAll(in: profilesDir)
        #expect(loaded.contains(good))
        #expect(!loaded.contains { $0.id == bad.id })
        #expect(FanProfile.selectable(id: good.id, among: loaded) == good)
        #expect(FanProfile.selectable(id: bad.id, among: loaded).id == "silent")
    }

    @Test("Corrupt profile files are skipped without dropping valid ones")
    func corruptFileSkipped() throws {
        let good = profile(id: "test_corrupt_neighbor")
        let corrupt = profilesDir.appendingPathComponent("test_corrupt.json")
        try good.save(in: profilesDir)
        try Data("{ not json".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: profilesDir) }

        #expect(FanProfile.loadAll(in: profilesDir).contains(good))
    }

    @Test("A profile that disappears mid-scan is skipped, not reported as corrupt")
    func vanishedFileSkipped() throws {
        let good = profile(id: "test_vanished_neighbor")
        try good.save(in: profilesDir)
        // A dangling symlink is listed by contentsOfDirectory but fails the read with
        // fileReadNoSuchFile — the same error as a profile deleted between the two steps,
        // without having to win a race to produce it.
        try FileManager.default.createSymbolicLink(
            at: profilesDir.appendingPathComponent("test_vanished.json"),
            withDestinationURL: profilesDir.appendingPathComponent("gone.json")
        )
        defer { try? FileManager.default.removeItem(at: profilesDir) }

        #expect(FanProfile.loadAll(in: profilesDir).contains(good))
    }

    @Test("Profile JSON without adaptive settings still decodes")
    func legacyJSONDecodes() throws {
        let json = """
        {"id":"test_legacy","name":"Legacy","curve":{"stopTemp":45,"startTemp":55,"ceilingTemp":65,
        "maxRPMPercent":0.5,"handsOff":false,"alwaysOn":false,"curveShape":"linear","rampUpPerSec":0.05,
        "rampDownPerSec":0.025,"sustainedTriggerSec":4,"instantEngage":false}}
        """
        let decoded = try JSONDecoder().decode(FanProfile.self, from: Data(json.utf8))
        #expect(decoded.curve.adaptive == nil)
        #expect(decoded.validationError == nil)
    }
    // MARK: - Smart button

    @Test("Adaptive profiles are Smart; the other built-ins are not")
    func smartProfiles() {
        #expect(FanProfile.smart.isSmart)
        #expect(profile(id: "test_smart_variant").isSmart)
        #expect(!FanProfile.builtIn.contains { $0.isSmart })
    }

    @Test("The Smart button turns on the last Smart profile used, else built-in Smart")
    func smartButtonProfile() {
        let variant = profile(id: "test_smart_variant")
        let profiles = FanProfile.builtIn + [variant]
        #expect(FanProfile.smartButtonProfile(lastID: variant.id, among: profiles) == variant)
        #expect(FanProfile.smartButtonProfile(lastID: nil, among: profiles) == .smart)
        #expect(FanProfile.smartButtonProfile(lastID: "test_deleted", among: profiles) == .smart)
        #expect(FanProfile.smartButtonProfile(lastID: "balanced", among: profiles) == .smart)
    }
    @Test("The Smart dropdown lists built-in Smart first, then custom Smart profiles")
    func smartDropdownProfiles() {
        let variant = profile(id: "test_smart_variant")
        let profiles = FanProfile.builtIn + [variant]
        #expect(FanProfile.smartProfiles(among: profiles) == [.smart, variant])
    }
}
