//
//  MonitorReadTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Monitor fast read")
struct MonitorReadTests {

    // MARK: - Key selection

    @Test("keeps only candidate keys whose key info reports a decodable size, in order")
    func selectsPresentDecodableKeys() {
        let info: [String: UInt32] = ["Tp01": 4, "Tg0D": 8, "TC0x": 0, "Tp03": 2]
        let selected = FanControl.monitorTempKeySizes(
            candidates: ["Tp01", "Tp02", "TC0x", "Tp03", "Tg0D"],
            keySize: { info[$0] }
        )
        #expect(selected.map(\.key) == ["Tp01", "Tg0D"])
        #expect(selected.map(\.size) == [4, 8])
    }

    @Test("SMC not ready (boot or wake): every key missing selects nothing")
    func allKeysMissing() {
        let selected = FanControl.monitorTempKeySizes(
            candidates: FanControl.safetyTempKeys,
            keySize: { _ in nil }
        )
        #expect(selected.isEmpty)
    }

    // MARK: - Re-check policy

    @Test("re-checks keys at start, after a skipped reading, and every 60 s")
    func keyRefreshPolicy() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Never checked (monitor start).
        #expect(ThermalMonitor.needsKeyRefresh(lastRefresh: nil, now: t0, lastTickSkipped: false))
        // Checked just now, last reading fine → no re-check.
        #expect(!ThermalMonitor.needsKeyRefresh(lastRefresh: t0, now: t0.addingTimeInterval(1), lastTickSkipped: false))
        // Last reading skipped (e.g. empty key list at boot → peak 0) → re-check.
        #expect(ThermalMonitor.needsKeyRefresh(lastRefresh: t0, now: t0.addingTimeInterval(1), lastTickSkipped: true))
        // 60 s elapsed → re-check.
        #expect(!ThermalMonitor.needsKeyRefresh(lastRefresh: t0, now: t0.addingTimeInterval(59.9), lastTickSkipped: false))
        #expect(ThermalMonitor.needsKeyRefresh(lastRefresh: t0, now: t0.addingTimeInterval(60), lastTickSkipped: false))
    }
}
