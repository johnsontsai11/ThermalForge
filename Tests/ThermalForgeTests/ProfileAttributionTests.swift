//
//  ProfileAttributionTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Capture attribution")
struct ProfileAttributionTests {

    private var quiet: FanProfile {
        FanProfile(id: "smart-mini-quiet", name: "Smart (Mac mini, quiet)",
                   curve: .init(stopTemp: 45, startTemp: 60, ceilingTemp: 85,
                                curveShape: .easeIn, sustainedTriggerSec: 6))
    }
    private var record: ActiveProfileRecord { ActiveProfileRecord(profile: quiet) }
    private var noHold: DaemonHoldState { .init(command: nil, owner: "none") }
    private var cliHold: DaemonHoldState { .init(command: "set 3073", owner: "cli") }
    private var appHold: DaemonHoldState { .init(command: "set 2757", owner: "app") }

    @Test("With the app in control, the profile gets the credit")
    func profileInControl() {
        let a = ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: appHold, holdAtEnd: appHold)
        #expect(a.profileInControl)
        #expect(a.profile?.id == "smart-mini-quiet")
        #expect(a.profileNote == nil)
    }

    @Test("A CLI hold spanning the capture revokes the profile's credit")
    func cliHoldRevokesCredit() throws {
        let a = ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: cliHold, holdAtEnd: cliHold)
        #expect(a.profileInControl == false)
        // The record is kept — knowing what was loaded is still useful — but the
        // note must make clear the curve did not produce these numbers.
        #expect(a.profile?.id == "smart-mini-quiet")
        let note = try #require(a.profileNote)
        #expect(note.contains("CLI"))
        #expect(note.contains("set 3073"))
        #expect(a.fanHold == cliHold)
    }

    @Test("A CLI hold seen at either end alone is still disqualifying")
    func cliHoldAtEitherEnd() {
        #expect(ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: cliHold,
                                           holdAtEnd: noHold).profileInControl == false)
        #expect(ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: noHold,
                                           holdAtEnd: cliHold).profileInControl == false)
    }

    @Test("The safety floor overriding to max also revokes credit — that is not the curve")
    func safetyOverrideRevokesCredit() throws {
        let suspended = DaemonHoldState(command: "set 2757", owner: "app", safetySuspended: true)
        let a = ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: suspended, holdAtEnd: suspended)
        #expect(a.profileInControl == false)
        #expect(try #require(a.profileNote).contains("safety"))
    }

    @Test("No profile record means nothing profile-driven produced the capture")
    func noRecordIsNotInControl() {
        let a = ProfileAttribution.resolve(lookup: .unavailable(note: "app not running"),
                                           holdAtStart: noHold, holdAtEnd: noHold)
        #expect(a.profileInControl == false)
        #expect(a.profile == nil)
        #expect(a.profileNote == "app not running")
    }

    @Test("An unreachable daemon leaves the hold unknown without falsely crediting the profile")
    func unknownHoldIsNotSilentlyTrusted() throws {
        let a = ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: nil, holdAtEnd: nil)
        #expect(a.profileInControl == false)
        #expect(try #require(a.profileNote).contains("could not be read"))
    }

    @Test("An idle daemon with no hold at all still credits the profile")
    func noHoldStillCredits() {
        let a = ProfileAttribution.resolve(lookup: .found(record),
                                           holdAtStart: noHold, holdAtEnd: noHold)
        #expect(a.profileInControl)
        #expect(a.fanHold == nil)
    }
}
