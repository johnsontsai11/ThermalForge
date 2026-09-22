//
//  ActiveProfile.swift
//  ThermalForge
//
//  A machine-readable record of the profile the APP is running, written by the app
//  on every profile change and read by `thermalforge log` so each capture says what
//  produced it.
//
//  This deliberately records the RUNNING profile, not the on-disk JSON. Profiles are
//  loaded once at app launch with no file watcher, so a profile edited since then is
//  not in effect; reading the JSON would report a curve that isn't controlling the fan.
//

import Foundation

/// The profile the app currently has loaded, as written to the sidecar.
public struct ActiveProfileRecord: Codable, Equatable {
    public let id: String
    public let name: String
    /// Where the record came from. Always "app" today; present so a future writer
    /// (e.g. the daemon) is distinguishable without breaking existing readers.
    public let source: String
    /// When the app last wrote this record (ISO-8601).
    public let asOf: String
    /// The writing app's pid, so a reader can tell a live record from a leftover one.
    public let pid: Int32
    public let curve: FanProfile.Curve

    /// Shared, never mutated after creation. Building an ISO8601DateFormatter costs
    /// ~87 us — a third of a sidecar write — and buys nothing per call.
    private static let isoFormatter = ISO8601DateFormatter()

    public init(profile: FanProfile, asOf: Date = Date(),
                pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                source: String = "app") {
        self.id = profile.id
        self.name = profile.name
        self.source = source
        self.asOf = Self.isoFormatter.string(from: asOf)
        self.pid = pid
        self.curve = profile.curve
    }
}

/// Why a lookup did or didn't yield a record. The failure cases carry the note that
/// goes into the capture's metadata, so a capture is never silently unattributed.
public enum ActiveProfileLookup: Equatable {
    case found(ActiveProfileRecord)
    case unavailable(note: String)

    public var record: ActiveProfileRecord? {
        if case .found(let r) = self { return r }
        return nil
    }

    public var note: String? {
        if case .unavailable(let n) = self { return n }
        return nil
    }
}

extension ActiveProfileRecord {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/active-profile.json")
    }

    /// True when `pid` is a live process. EPERM means it exists but is owned by
    /// someone else, which still counts as running.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func write(to url: URL = ActiveProfileRecord.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Read the sidecar. A record whose writer is gone is reported as unavailable
    /// rather than returned: the app not running means nothing is driving the fan
    /// from a profile, and attributing the capture to a dead app would be wrong.
    public static func read(from url: URL = ActiveProfileRecord.defaultURL,
                            isAlive: (Int32) -> Bool = ActiveProfileRecord.processIsAlive)
        -> ActiveProfileLookup {
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable(note: "no active-profile record (app has not run since install)")
        }
        guard let record = try? JSONDecoder().decode(ActiveProfileRecord.self, from: data) else {
            return .unavailable(note: "active-profile record unreadable")
        }
        guard isAlive(record.pid) else {
            return .unavailable(note: "app not running (last profile: \(record.name))")
        }
        return .found(record)
    }
}

// MARK: - Capture Attribution

/// Who actually drove the fan for a capture. The sidecar says which profile the app
/// has LOADED, which is not the same as the profile being in control: a CLI hold
/// (`thermalforge set …`) suspends the app's automatic control while leaving
/// `activeProfile` untouched, and the daemon's safety floor can override any hold.
/// Crediting the curve for fan speeds it didn't command is exactly the mis-attribution
/// the sidecar exists to prevent, so resolve the two together.
public struct ProfileAttribution: Equatable {
    public let profile: ActiveProfileRecord?
    public let profileNote: String?
    /// False whenever anything other than the profile's curve may have driven the fan.
    /// A capture with this false is not evidence about the curve.
    public let profileInControl: Bool
    /// The hold in force, when one was seen. Nil when the daemon reported none.
    public let fanHold: DaemonHoldState?

    /// Holds are sampled at the capture's start and end. A hold that both begins and
    /// ends strictly inside the window is not detected — the realistic case, a hold
    /// left in place across a run, is.
    public static func resolve(lookup: ActiveProfileLookup,
                               holdAtStart: DaemonHoldState?,
                               holdAtEnd: DaemonHoldState?) -> ProfileAttribution {
        let record = lookup.record
        let samples = [holdAtStart, holdAtEnd]

        // An unreadable daemon is unknown, not "no hold" — don't credit the profile
        // on the strength of a failed read.
        if samples.contains(where: { $0 == nil }) {
            return .init(profile: record,
                         profileNote: lookup.note ?? "fan hold could not be read (daemon unreachable)",
                         profileInControl: false,
                         fanHold: samples.compactMap { $0 }.first { !$0.isEmpty })
        }
        let seen = samples.compactMap { $0 }

        guard record != nil else {
            return .init(profile: nil, profileNote: lookup.note,
                         profileInControl: false, fanHold: seen.first { !$0.isEmpty })
        }
        if let cli = seen.first(where: { $0.isCLIHold }) {
            return .init(profile: record,
                         profileNote: "fan held from the CLI (\(cli.command ?? "?")) — the profile was suspended and did not produce this capture",
                         profileInControl: false, fanHold: cli)
        }
        if let suspended = seen.first(where: { $0.safetySuspended }) {
            return .init(profile: record,
                         profileNote: "the daemon's safety floor overrode the profile during this capture",
                         profileInControl: false, fanHold: suspended)
        }
        return .init(profile: record, profileNote: lookup.note,
                     profileInControl: true, fanHold: seen.first { !$0.isEmpty })
    }
}
