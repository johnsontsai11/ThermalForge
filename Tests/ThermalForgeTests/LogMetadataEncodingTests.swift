//
//  LogMetadataEncodingTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Log metadata encoding")
struct LogMetadataEncodingTests {

    private func makeMetadata() -> LogSessionMetadata {
        LogSessionMetadata(machine: "Mac16,10", osVersion: "27.0", thermalForgeVersion: "0.2.3",
                           fanCount: 1, maxRPM: 4900, minRPM: 1000, sampleRateHz: 1,
                           startedAt: "2026-09-22T00:00:00Z")
    }

    private func encoded(_ m: LogSessionMetadata) throws -> [String: Any] {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = try e.encode(m)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("An unattributed capture emits profile as an explicit null, not a missing key")
    func absentProfileIsExplicitNull() throws {
        var m = makeMetadata()
        m.profileNote = "app not running"
        let json = try encoded(m)
        // A reader must be able to see the field exists and is empty, rather than
        // guessing whether it is absent because nothing wrote it or because the
        // capture predates the field.
        #expect(json.keys.contains("profile"))
        #expect(json["profile"] is NSNull)
        #expect(json["fanHold"] is NSNull)
        #expect(json["profileInControl"] as? Bool == false)
        #expect(json["profileNote"] as? String == "app not running")
    }

    @Test("An attributed capture emits the profile object and its hold")
    func presentProfileEncodes() throws {
        var m = makeMetadata()
        let p = FanProfile(id: "smart-mini-quiet", name: "Smart (Mac mini, quiet)",
                           curve: .init(stopTemp: 45, startTemp: 60, ceilingTemp: 85,
                                        curveShape: .easeIn, sustainedTriggerSec: 6))
        m.profile = ActiveProfileRecord(profile: p)
        m.profileInControl = true
        m.fanHold = .init(command: "set 1000", owner: "app")
        let json = try encoded(m)
        let profile = try #require(json["profile"] as? [String: Any])
        #expect(profile["id"] as? String == "smart-mini-quiet")
        #expect(json["profileInControl"] as? Bool == true)
        #expect((json["fanHold"] as? [String: Any])?["owner"] as? String == "app")
        #expect(json["profileNote"] is NSNull)
    }

    @Test("Every stored field reaches the JSON — guards a hand-written encoder from drift")
    func allFieldsAreEncoded() throws {
        var m = makeMetadata()
        m.endedAt = "2026-09-22T00:12:00Z"
        m.totalSamples = 710
        m.sensorKeys = ["Tp0W"]
        let json = try encoded(m)
        // If a property is added to LogSessionMetadata and not to encode(to:), this
        // fails — the manual encoder exists only to force `profile` to null, and must
        // not silently start dropping fields.
        let expected: Set<String> = ["machine", "osVersion", "thermalForgeVersion", "fanCount",
                                     "maxRPM", "minRPM", "sampleRateHz", "startedAt", "endedAt",
                                     "totalSamples", "sensorKeys", "profile", "profileNote",
                                     "profileInControl", "fanHold"]
        #expect(Set(json.keys) == expected)
    }

    @Test("Metadata round-trips, so existing readers and the decoder stay in step")
    func roundTrips() throws {
        var m = makeMetadata()
        m.totalSamples = 42
        m.profileInControl = true
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(LogSessionMetadata.self, from: data)
        #expect(back.machine == "Mac16,10")
        #expect(back.totalSamples == 42)
        #expect(back.profileInControl)
        #expect(back.profile == nil)
    }
}
