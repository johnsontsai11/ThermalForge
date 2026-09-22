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

    public init(profile: FanProfile, asOf: Date = Date(),
                pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                source: String = "app") {
        self.id = profile.id
        self.name = profile.name
        self.source = source
        self.asOf = ISO8601DateFormatter().string(from: asOf)
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
