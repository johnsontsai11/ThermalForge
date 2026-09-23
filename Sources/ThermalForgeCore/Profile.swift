//
//  Profile.swift
//  ThermalForge
//
//  Fan control profiles with proportional temperature curves.
//
//  Each profile defines a curve that maps temperature to fan speed,
//  along with per-profile ramp rates, sustained triggers, and curve shapes.
//
//  Based on Apple fan hardware research:
//  - 0 to minimum RPM is binary (hardware limitation)
//  - Above minimum, proportional ramping with configurable curve shape
//  - Start/stop cycles are the #1 fan bearing wear factor
//  - At least 5°C hysteresis between start and stop thresholds
//  - Ramp governors are acoustic comfort, not bearing protection
//

import Foundation

// MARK: - Curve Shape

/// How the profile maps temperature position to fan speed in the proportional zone.
public enum CurveShape: String, Codable, Equatable {
    /// pos * max — direct proportional response
    case linear
    /// pos² * max — quiet start, accelerates with heat
    case easeIn
    /// √pos * max — fast initial response, levels off
    case easeOut
    /// pos²(3-2pos) * max — smooth at both ends
    case sCurve

    /// Map a position in the proportional zone (0.0–1.0) to a shaped fraction (0.0–1.0).
    public func apply(_ position: Float) -> Float {
        switch self {
        case .linear: return position
        case .easeIn: return position * position
        case .easeOut: return sqrt(position)
        case .sCurve: return position * position * (3 - 2 * position)
        }
    }
}

// MARK: - Profile Model

public struct FanProfile: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let curve: Curve

    /// Defines how the profile maps temperature to fan speed.
    public struct Curve: Codable, Equatable {
        /// Below this temperature, fans turn off (return to Apple auto).
        /// Must be at least 5°C below startTemp for hysteresis.
        public let stopTemp: Float

        /// Above this temperature, fans engage (after sustained trigger is met).
        public let startTemp: Float

        /// Temperature at which fan speed reaches maxRPMPercent.
        /// Ignored when instantEngage is true (binary on/off).
        public let ceilingTemp: Float

        /// Maximum fan speed as fraction of max RPM (0.0–1.0).
        public let maxRPMPercent: Float

        /// If true, this profile doesn't control fans — stays in Apple auto mode.
        public let handsOff: Bool

        /// If true, fans are always at maxRPMPercent regardless of temperature.
        public let alwaysOn: Bool

        /// How temperature maps to fan speed in the proportional zone.
        public let curveShape: CurveShape

        /// Max fan speed increase per second (fraction of max RPM per second).
        /// Ignored when instantEngage is true.
        public let rampUpPerSec: Float

        /// Max fan speed decrease per second (fraction of max RPM per second).
        public let rampDownPerSec: Float

        /// Seconds of sustained temperature above startTemp before fans engage.
        /// Filters transient spikes that resolve on their own.
        public let sustainedTriggerSec: Float

        /// If true, skip ramp-up governor — jump directly to maxRPMPercent.
        /// Ramp-down governor still applies for smooth deceleration.
        public let instantEngage: Bool

        /// If set, the profile runs Smart's adaptive logic (rate-of-change boost, optional
        /// calibration, smoothed control temperature) instead of the plain curve.
        /// Optional so saved profiles without it still decode.
        public let adaptive: Adaptive?

        /// Tuning for Smart-style adaptive profiles.
        public struct Adaptive: Codable, Equatable {
            /// Seconds of peak-temperature history averaged into the control temperature.
            /// 0 reacts to each raw reading. The 95°C safety override always uses raw readings.
            public let smoothingSec: Float
            /// Fan fraction added per °C/sec of temperature rise. When a calibration table is in
            /// use, the boost is 0.75 × this, growing to 1.5 × this at the ceiling (built-in
            /// Smart: 0.2 uncalibrated, 0.15–0.3 calibrated).
            public let rateBoost: Float
            /// Use the machine calibration table (if one exists) instead of the curve.
            public let useCalibration: Bool

            public init(smoothingSec: Float = 0, rateBoost: Float = 0.2, useCalibration: Bool = true) {
                self.smoothingSec = smoothingSec
                self.rateBoost = rateBoost
                self.useCalibration = useCalibration
            }
        }

        public init(stopTemp: Float = 50, startTemp: Float = 55, ceilingTemp: Float = 70,
                    maxRPMPercent: Float = 0.6, handsOff: Bool = false, alwaysOn: Bool = false,
                    curveShape: CurveShape = .linear, rampUpPerSec: Float = 0.05,
                    rampDownPerSec: Float = 0.025, sustainedTriggerSec: Float = 8,
                    instantEngage: Bool = false, adaptive: Adaptive? = nil) {
            self.stopTemp = stopTemp
            self.startTemp = startTemp
            self.ceilingTemp = ceilingTemp
            self.maxRPMPercent = maxRPMPercent
            self.handsOff = handsOff
            self.alwaysOn = alwaysOn
            self.curveShape = curveShape
            self.rampUpPerSec = rampUpPerSec
            self.rampDownPerSec = rampDownPerSec
            self.sustainedTriggerSec = sustainedTriggerSec
            self.instantEngage = instantEngage
            self.adaptive = adaptive
        }

        /// Calculate the target fan speed percentage (0.0–1.0) for a given temperature.
        /// Returns nil if fans should be off (Apple auto).
        /// Returns 0.001 as a signal to keep fans at minimum RPM (hysteresis band).
        public func targetPercent(at temp: Float, fansCurrentlyRunning: Bool) -> Float? {
            // Always-on profiles ignore temperature
            if alwaysOn { return maxRPMPercent }

            // Hands-off profiles don't control fans
            if handsOff { return nil }

            // Below stop threshold and fans not running: stay off
            if temp <= stopTemp && !fansCurrentlyRunning { return nil }

            // In hysteresis band (between stop and start): maintain current state
            if temp > stopTemp && temp < startTemp {
                return fansCurrentlyRunning ? 0.001 : nil // 0.001 signals "keep at minimum"
            }

            // Below stop threshold but fans are running: turn off
            if temp <= stopTemp && fansCurrentlyRunning { return nil }

            // Above start: apply curve shape
            if temp >= startTemp {
                if temp >= ceilingTemp { return maxRPMPercent }

                // Instant engage profiles jump directly to max (no proportional curve up)
                if instantEngage { return maxRPMPercent }

                let position = (temp - startTemp) / (ceilingTemp - startTemp)
                return curveShape.apply(position) * maxRPMPercent
            }

            return nil
        }

        /// Adaptive (Smart-style) target fan fraction for a control temperature, before the
        /// fan's minimum-RPM floor and ramp governors are applied by the monitor.
        /// `rate` is the temperature rise in °C/sec; `calibration` is ignored unless the
        /// profile's `adaptive.useCalibration` is true.
        public func adaptiveTargetPercent(at temp: Float, rate: Float,
                                          calibration: CalibrationData?) -> Float {
            let settings = adaptive ?? Adaptive()
            let range = ceilingTemp - startTemp
            let position = range > 0 ? Swift.min(Swift.max((temp - startTemp) / range, 0), 1) : 1
            var target: Float

            if settings.useCalibration, let cal = calibration, let calPct = cal.fanPercentForTemp(temp) {
                // Calibrated: machine-specific temp→fan lookup. Boost scales with proximity
                // to the ceiling (0.75 × rateBoost keeps built-in Smart at its original 0.15).
                target = calPct
                if rate > 0 {
                    target = min(target + rate * settings.rateBoost * 0.75 * (1 + position), maxRPMPercent)
                }
            } else {
                target = curveShape.apply(position) * maxRPMPercent
                if rate > 0 {
                    target = min(target + rate * settings.rateBoost, maxRPMPercent)
                }
            }

            if temp > ceilingTemp { target = maxRPMPercent }
            return Swift.min(Swift.max(target, 0), maxRPMPercent)
        }
    }

    /// One-line description of the knobs that actually change fan behaviour, for the
    /// launch log line. Profile *identity* is the name; this is the live *tuning*, so a
    /// log reader can tell which curve was running without reading the JSON off disk
    /// (which may have been edited since the app last loaded it).
    public var curveSummary: String {
        if curve.handsOff { return "hands-off (macOS owns the fans)" }
        let n = { (v: Float) -> String in
            v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v)
        }
        var parts = ["stop \(n(curve.stopTemp))", "start \(n(curve.startTemp))",
                     "ceiling \(n(curve.ceilingTemp))",
                     "cap \(Int((curve.maxRPMPercent * 100).rounded()))%",
                     curve.curveShape.rawValue,
                     "trigger \(n(curve.sustainedTriggerSec))s"]
        if let a = curve.adaptive {
            parts.append("smoothing \(n(a.smoothingSec))s")
            parts.append("boost \(n(a.rateBoost))")
            if a.useCalibration { parts.append("calibrated") }
        }
        return parts.joined(separator: ", ")
    }

    public init(id: String, name: String, curve: Curve) {
        self.id = id
        self.name = name
        self.curve = curve
    }

    // Legacy support — old profiles used triggers/fanBehavior
    public struct Triggers: Codable, Equatable {
        public let cpuTemp: Float?
        public let gpuTemp: Float?
        public let memPressure: Float?
        public init(cpuTemp: Float? = nil, gpuTemp: Float? = nil, memPressure: Float? = nil) {
            self.cpuTemp = cpuTemp; self.gpuTemp = gpuTemp; self.memPressure = memPressure
        }
    }
    public struct FanBehavior: Codable, Equatable {
        public let mode: Mode
        public let rpmPercent: Float
        public enum Mode: String, Codable, Equatable { case auto, manual }
        public init(mode: Mode, rpmPercent: Float) { self.mode = mode; self.rpmPercent = rpmPercent }
    }
}

// MARK: - Built-in Profiles

extension FanProfile {
    /// Silent (Apple Default): hands-off, let Apple control fans. ThermalForge monitors only.
    public static let silent = FanProfile(
        id: "silent",
        name: "Silent (Apple Default)",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 55,
                     maxRPMPercent: 0, handsOff: true)
    )

    /// Balanced: gentle ease-in curve for everyday use.
    /// Quiet at low temps (pos²), ramps harder as heat builds.
    /// 8-second sustained trigger filters all transients.
    public static let balanced = FanProfile(
        id: "balanced",
        name: "Balanced",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 70,
                     maxRPMPercent: 0.60, curveShape: .easeIn,
                     rampUpPerSec: 0.05, rampDownPerSec: 0.025,
                     sustainedTriggerSec: 8)
    )

    /// Performance: linear curve, fast response. Thermals over noise.
    /// 4-second sustained trigger, 2× ramp-up speed vs Balanced.
    public static let performance = FanProfile(
        id: "performance",
        name: "Performance",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 65,
                     maxRPMPercent: 0.85, curveShape: .linear,
                     rampUpPerSec: 0.10, rampDownPerSec: 0.04,
                     sustainedTriggerSec: 4)
    )

    /// Max: attack dog. Instant 100% after 5-second sustained trigger at 65°C.
    /// They spike, we spike. Ramp-down governor lets temps stabilize before backing off.
    public static let max = FanProfile(
        id: "max",
        name: "Max",
        curve: Curve(stopTemp: 50, startTemp: 65, ceilingTemp: 65,
                     maxRPMPercent: 1.0, curveShape: .linear,
                     rampUpPerSec: 1.0, rampDownPerSec: 0.025,
                     sustainedTriggerSec: 5, instantEngage: true)
    )

    /// Smart: proactive S-curve with rate-of-change awareness.
    /// Starts 2°C earlier (53°C) to get ahead of rising temps.
    /// Uses calibration data when available. 6-second sustained trigger.
    public static let smart = FanProfile(
        id: "smart",
        name: "Smart",
        curve: Curve(stopTemp: 50, startTemp: 53, ceilingTemp: 85,
                     maxRPMPercent: 1.0, curveShape: .sCurve,
                     rampUpPerSec: 0.05, rampDownPerSec: 0.025,
                     sustainedTriggerSec: 6,
                     adaptive: Curve.Adaptive(smoothingSec: 0, rateBoost: 0.2, useCalibration: true))
    )

    public static let builtIn: [FanProfile] = [silent, balanced, performance, max]

    /// Resolve a persisted profile id to a known profile for launch restore. Searches
    /// `profiles` (built-ins plus saved custom profiles by default) plus Smart (which is
    /// surfaced via its own button, so it isn't in `builtIn`). Returns Silent when the id
    /// is nil (nothing saved) or unrecognized (a profile removed, renamed, or a custom
    /// file deleted), so a stale saved id never crashes.
    public static func selectable(id: String?, among profiles: [FanProfile] = loadAll()) -> FanProfile {
        guard let id else { return .silent }
        return (profiles + [smart]).first { $0.id == id } ?? .silent
    }

    /// Smart-type profiles (built-in Smart and custom adaptive ones) light the menu's Smart button.
    public var isSmart: Bool { curve.adaptive != nil }

    /// The Smart button's dropdown: built-in Smart, then the Smart profiles in `profiles`.
    public static func smartProfiles(among profiles: [FanProfile] = loadAll()) -> [FanProfile] {
        [smart] + profiles.filter(\.isSmart)
    }

    /// The profile the Smart button turns on: the last Smart profile used, or built-in Smart
    /// when none is saved or it no longer exists.
    public static func smartButtonProfile(lastID: String?, among profiles: [FanProfile] = loadAll()) -> FanProfile {
        let last = selectable(id: lastID, among: profiles)
        return last.isSmart ? last : .smart
    }

    /// Whether switching `from` → `to` keeps the fan's current speed and sustained-heat
    /// count, so the new profile picks up where the old one was instead of handing the
    /// fan back to macOS and re-waiting its trigger. Only between profiles that both
    /// control the fan, and never when taking over a CLI hold (that hold gets cleared).
    public static func switchKeepsFans(from: FanProfile, to: FanProfile, tookHold: Bool) -> Bool {
        !tookHold && !from.curve.handsOff && !to.curve.handsOff
    }
}

// MARK: - Persistence

extension FanProfile {
    /// Internal, not private: tests drive `save(in:)` / `loadAll(in:)` with a temp directory
    /// so fixtures never land in the user's real profile folder (and their decode failures
    /// never reach the user's real log).
    static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles")
    }

    public func save() throws {
        try save(in: Self.profilesDirectory)
    }

    func save(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    public static func loadAll() -> [FanProfile] {
        loadAll(in: profilesDirectory)
    }

    static func loadAll(in dir: URL) -> [FanProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            return builtIn
        }

        var profiles = builtIn
        for file in files where file.pathExtension == "json" {
            let profile: FanProfile
            do {
                profile = try JSONDecoder().decode(FanProfile.self, from: Data(contentsOf: file))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Deleted between listing the directory and reading it — the user removed a
                // profile mid-scan. Nothing is wrong and nothing is lost, so it isn't an error.
                continue
            } catch {
                TFLogger.shared.error("Skipped profile \(file.lastPathComponent): unreadable or not valid profile JSON (\(error))")
                continue
            }
            if let error = profile.validationError {
                TFLogger.shared.error("Skipped profile \(file.lastPathComponent): \(error)")
                continue
            }
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profiles.append(profile)
            }
        }
        return profiles
    }

    /// Why a saved profile can't be used, or nil if it's sane.
    public var validationError: String? {
        let c = curve
        if id == FanProfile.smart.id { return "id \"smart\" is reserved for the built-in Smart profile" }
        if c.stopTemp > c.startTemp { return "stopTemp \(c.stopTemp) is above startTemp \(c.startTemp)" }
        if c.startTemp > c.ceilingTemp { return "startTemp \(c.startTemp) is above ceilingTemp \(c.ceilingTemp)" }
        if !(0...1).contains(c.maxRPMPercent) { return "maxRPMPercent \(c.maxRPMPercent) is outside 0–1" }
        if c.rampUpPerSec <= 0 || c.rampDownPerSec <= 0 { return "ramp rates must be above 0" }
        if c.sustainedTriggerSec < 0 { return "sustainedTriggerSec must not be negative" }
        if let a = c.adaptive {
            if !(0...60).contains(a.smoothingSec) { return "smoothingSec \(a.smoothingSec) is outside 0–60" }
            if !(0...1).contains(a.rateBoost) { return "rateBoost \(a.rateBoost) is outside 0–1" }
        }
        return nil
    }
}

// MARK: - Safety

extension FanProfile {
    /// Hard safety threshold — overrides any profile that controls the fans
    public static let safetyTempThreshold: Float = 95.0
    /// Hysteresis deadband to prevent oscillation
    public static let hysteresisDegrees: Float = 5.0
    /// How long the peak must stay at/above the threshold before Smart profiles and the
    /// daemon floor override. Measured Mac mini M4 Tp0W jumps last 1–2 s (max seen 2.1 s).
    public static let safetySustainSec: TimeInterval = 3
    /// Lowest peak CPU/GPU temperature treated as a real reading. Just after wake the
    /// SMC reports a constant 7.3°C before its sensors are ready; a running chip
    /// indoors never reads this low.
    public static let minPlausibleTemp: Float = 15.0

    /// Whether a peak temperature can be trusted to drive fan decisions.
    public static func isPlausibleTemp(_ temp: Float) -> Bool {
        temp >= minPlausibleTemp
    }

    /// Whether the monitor's safety override takes the fans to max at this peak.
    /// Hands-off profiles (Silent) never do: macOS owns the fans there, just as the
    /// daemon's thermal floor leaves auto alone. Smart (adaptive) profiles also need the
    /// heat `sustained` (see `SustainedHeat`). On the Mac mini M4, Tp0W alone jumps past
    /// 95°C under load, which otherwise blasted the fan to max and straight back.
    public func safetyOverrideEngages(at temp: Float, sustained: Bool) -> Bool {
        !curve.handsOff && temp >= Self.safetyTempThreshold && (curve.adaptive == nil || sustained)
    }
}
