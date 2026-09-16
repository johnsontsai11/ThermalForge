//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Dual-cadence design:
//  - Thermal tick (200ms): read temps, calculate curve, apply ramp governor, write fan speed
//  - Monitor tick (2s): process capture, anomaly detection, history logging
//
//  Every cadence is written in seconds and converted to ticks against `tickInterval`,
//  so changing the tick rate costs less CPU without changing any timing behaviour.
//

import Darwin
import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    case setRPM(Float)
    case setFan(index: Int, rpm: Float)
    case resetAuto

    /// A hold keeps fans at a manual setting (so an unsupervised one-shot could
    /// be reverted by the watchdog); resetAuto hands control back and isn't held.
    public var isHold: Bool {
        switch self {
        case .setMax, .setRPM, .setFan: return true
        case .resetAuto: return false
        }
    }

    /// Per-fan commands need the 0.1.5 `setfan` socket verb; older daemons
    /// reject them, so the router must version-gate and fall back to direct SMC.
    public var isPerFan: Bool {
        if case .setFan = self { return true }
        return false
    }
}

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Rolling Average

/// Mean of the most recent `capacity` samples. Used to smooth the control temperature
/// for adaptive profiles so brief per-core spikes don't drive the fans.
struct RollingAverage {
    let capacity: Int
    private var samples: [Float] = []
    private var next = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Add a sample and return the mean of the retained window.
    mutating func add(_ value: Float) -> Float {
        if samples.count < capacity {
            samples.append(value)
        } else {
            samples[next] = value
            next = (next + 1) % capacity
        }
        return samples.reduce(0, +) / Float(samples.count)
    }
}

// MARK: - Fan Ramp

/// The fan fraction the monitor has applied, moved toward each tick's target at the
/// profile's ramp rates. `step` returns the RPM to send, floored at the fan's minimum.
/// Below the floor every step maps to the same RPM, so only the first one is sent.
struct FanRamp {
    private(set) var appliedPercent: Float = 0
    /// The last RPM `step` returned; nil after a reset, so the next step always sends.
    private var sentRPM: Float?

    /// Step toward `target` (0–1) by at most `up`/`down` per tick (`instant` skips the
    /// up governor). Returns the RPM to send, or nil when nothing needs sending.
    mutating func step(toward target: Float, up: Float, down: Float, instant: Bool,
                       minRPM: Float, maxRPM: Float) -> Float? {
        var percent = target
        if percent > appliedPercent {
            if !instant { percent = min(percent, appliedPercent + up) }
        } else if percent < appliedPercent {
            percent = max(percent, appliedPercent - down)
        }
        guard abs(percent - appliedPercent) > 0.002 else { return nil }
        appliedPercent = percent
        // Whole RPM: `minRPM / maxRPM × maxRPM` can land a hair above minRPM and resend it.
        let rpm = max(maxRPM * percent, minRPM).rounded()
        guard rpm != sentRPM else { return nil }
        sentRPM = rpm
        return rpm
    }

    /// Record a fan state set outside `step`: 0 when fans go back to macOS, 1 at max.
    mutating func reset(to percent: Float) {
        appliedPercent = percent
        sentRPM = nil
    }
}

/// Median of the most recent `capacity` samples. Used for anomaly logging: a per-core
/// blip shorter than half the window vanishes, while a real step keeps its full size.
struct RollingMedian {
    let capacity: Int
    private var samples: [Float] = []
    private var next = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Add a sample and return the median of the retained window.
    mutating func add(_ value: Float) -> Float {
        if samples.count < capacity {
            samples.append(value)
        } else {
            samples[next] = value
            next = (next + 1) % capacity
        }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// One process's cumulative CPU time (user + system), in nanoseconds.
struct ProcessCPUSample {
    let pid: pid_t
    let name: String
    let cpuNs: UInt64
}

/// Per-process CPU share between consecutive samples, for the anomaly log's process history.
/// macOS leaves `kinfo_proc.p_pctcpu` at 0, so the share comes from CPU time deltas. A pid
/// with no usable baseline (new, or its CPU time went backwards after pid reuse) is skipped.
struct ProcessCPUTracker {
    private var previous: [pid_t: UInt64] = [:]
    private var previousAt: UInt64?

    /// "name(12.3%), ..." for the top 5 above 0.1% of a core, "idle" if none, or
    /// "unavailable" on the first sample (no baseline yet).
    mutating func update(_ samples: [ProcessCPUSample], at nowNs: UInt64) -> String {
        defer {
            previous = Dictionary(samples.map { ($0.pid, $0.cpuNs) }, uniquingKeysWith: { $1 })
            previousAt = nowNs
        }
        guard let lastAt = previousAt, nowNs > lastAt else { return "unavailable" }
        let elapsed = Double(nowNs - lastAt)
        let busy = samples.compactMap { sample -> (name: String, percent: Double)? in
            guard let before = previous[sample.pid], sample.cpuNs >= before else { return nil }
            let percent = Double(sample.cpuNs - before) / elapsed * 100
            return percent > 0.1 ? (sample.name, percent) : nil
        }
        let top5 = busy.sorted { $0.percent > $1.percent }.prefix(5)
        if top5.isEmpty { return "idle" }
        return top5.map { "\($0.name)(\(String(format: "%.1f", $0.percent))%)" }.joined(separator: ", ")
    }
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    /// Each tick is one SMC sweep, and those reads dominate the monitor's CPU cost,
    /// so this is the one knob trading CPU for control resolution.
    private let tickInterval: Float

    /// Default thermal tick. Ramp governors move the fan ~20 RPM per tick and the
    /// shortest sustained trigger is seconds long, so polling finer buys no control.
    public static let defaultTickInterval: Float = 0.2

    /// Monitor work: process capture, anomaly detection, history logging.
    private static let monitorIntervalSec: Float = 2
    /// onUpdate cadence. The SMC refreshes temperatures about once a second, so a
    /// faster UI only redraws the same readings. 5 × the 200ms default tick.
    private static let uiUpdateIntervalSec: Float = 1
    /// Window for the anomaly median (see `anomalyMedian`).
    private static let anomalyMedianSec: Float = 6

    /// Cadences in ticks, derived from `tickInterval` so they keep their wall-clock
    /// meaning whatever the tick rate.
    private var monitorCadence: Int { Self.ticks(for: Self.monitorIntervalSec, interval: tickInterval) }
    private var uiUpdateCadence: Int { Self.ticks(for: Self.uiUpdateIntervalSec, interval: tickInterval) }

    /// Whole ticks spanning `seconds`, never fewer than one.
    static func ticks(for seconds: Float, interval: Float) -> Int {
        max(Int((seconds / interval).rounded()), 1)
    }

    private var tickCounter = 0

    // MARK: - Fan State

    private var fanRamp = FanRamp()
    private var fansCurrentlyRunning = false
    private var sustainedAboveCount = 0
    /// Consecutive ticks skipped for an implausible peak (see `FanProfile.isPlausibleTemp`).
    private var skippedReadings = 0
    /// Whether the peak has stayed ≥95°C long enough for Smart profiles to override.
    private var safetyHeat = SustainedHeat()
    /// When `fanControl.refreshMonitorKeys()` last ran; nil until the first tick.
    private var lastKeyRefresh: Date?
    static let keyRefreshInterval: TimeInterval = 60

    // MARK: - Smart Profile State

    private var tempHistory: [Float] = []
    /// Smoothed control temperature for adaptive profiles with `smoothingSec > 0`.
    private var controlTempAverage: RollingAverage?

    // MARK: - Anomaly Detection

    /// Tracks temps over 30 seconds (15 readings at 2s monitor cadence)
    private var anomalyHistory: [Float] = []
    /// Median of the peak over `anomalyMedianSec`. Tp0W on the Mac mini M4 blips
    /// ~27°C for 1–2s every few seconds at idle; the raw peak logged each blip twice.
    private var anomalyMedian: RollingMedian
    private var isCalibrating = false

    // MARK: - Process Buffer

    /// Rolling buffer — captures what was running BEFORE a spike.
    /// 15 snapshots × 2 seconds = 30 seconds of pre-spike history.
    private var processBuffer: [(timestamp: String, processes: String)] = []
    /// CPU time per pid from the previous capture, to turn into a share of a core.
    private var processCPU = ProcessCPUTracker()
    private let isoFormatter = ISO8601DateFormatter()

    /// Call this to suppress anomaly logging during calibration
    public func setCalibrating(_ value: Bool) {
        queue.async { self.isCalibrating = value }
    }
    private var calibration: CalibrationData? = {
        guard let data = CalibrationData.load() else { return nil }
        if let error = data.validationError {
            TFLogger.shared.error("Calibration data rejected: \(error)")
            return nil
        }
        return data
    }()

    /// Called on UI update cadence (`uiUpdateIntervalSec`) with updated status
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(fanControl: FanControl,
                profile: FanProfile = .silent,
                tickInterval: Float = ThermalMonitor.defaultTickInterval) {
        let interval = max(tickInterval, 0.01)
        self.fanControl = fanControl
        self.activeProfile = profile
        self.tickInterval = interval
        self.anomalyMedian = RollingMedian(
            capacity: Self.ticks(for: Self.anomalyMedianSec, interval: interval)
        )
        self.controlTempAverage = makeControlTempAverage(for: profile)
    }

    /// A rolling average sized to the profile's smoothing window, or nil for raw readings.
    private func makeControlTempAverage(for profile: FanProfile) -> RollingAverage? {
        guard let seconds = profile.curve.adaptive?.smoothingSec, seconds > tickInterval else { return nil }
        return RollingAverage(capacity: Int((seconds / tickInterval).rounded()))
    }

    // MARK: - Lifecycle

    /// Runs the thermal tick at `tickInterval`. The rate is fixed at init so the
    /// derived cadences can't drift from the timer that drives them.
    public func start() {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Double(tickInterval))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile
            fanRamp.reset(to: 0)
            fansCurrentlyRunning = false
            sustainedAboveCount = 0
            tickCounter = 0
            controlTempAverage = makeControlTempAverage(for: profile)

            if profile.curve.adaptive != nil {
                // Reset adaptive state and reload calibration data
                tempHistory.removeAll()
                let loaded = CalibrationData.load()
                if let error = loaded?.validationError {
                    TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }

            state = .idle
        }
    }

    // MARK: - Polling

    /// Re-discover sensor keys at start, after a skipped reading (a discovery made while
    /// the SMC wasn't ready reads as peak 0), and every `keyRefreshInterval`.
    static func needsKeyRefresh(lastRefresh: Date?, now: Date, lastTickSkipped: Bool) -> Bool {
        guard let lastRefresh else { return true }
        return lastTickSkipped || now.timeIntervalSince(lastRefresh) >= keyRefreshInterval
    }

    private func tick() {
        let now = Date()
        if Self.needsKeyRefresh(lastRefresh: lastKeyRefresh, now: now, lastTickSkipped: skippedReadings > 0) {
            fanControl.refreshMonitorKeys()
            lastKeyRefresh = now
        }
        guard let status = try? fanControl.monitorStatus() else { return }

        // Peak CPU (TC/Tp) + GPU (TG/Tg) — the shared safety-floor sensor extraction,
        // so the client monitor and the daemon's floor read the identical value.
        let maxTemp = status.safetyPeakTemp

        // Implausible peak (e.g. 7.3°C just after wake): skip the whole tick so fans
        // keep their last command. Logged once per run, not every 100ms.
        guard FanProfile.isPlausibleTemp(maxTemp) else {
            if skippedReadings == 0 {
                let fan0 = status.fans.first
                TFLogger.shared.info(
                    "Skipping implausible readings: peak \(String(format: "%.1f", maxTemp))°C | " +
                    "Fan0: \(fan0?.actualRPM ?? 0) RPM, range \(fan0?.minRPM ?? 0)–\(fan0?.maxRPM ?? 0) RPM " +
                    "(\(fan0?.mode ?? "?")) | Profile: \(activeProfile.name)"
                )
            }
            skippedReadings += 1
            return
        }
        if skippedReadings > 0 {
            TFLogger.shared.info("Readings plausible again after \(skippedReadings) skipped ticks")
            skippedReadings = 0
        }
        latestStatus = status

        // Control temperature: smoothed for adaptive profiles that ask for it, raw otherwise.
        // Updated every tick (even during a safety override) so the window stays continuous.
        let controlTemp = controlTempAverage?.add(maxTemp) ?? maxTemp
        // Anomaly temperature: median-filtered so brief per-core blips aren't logged as spikes.
        let anomalyTemp = anomalyMedian.add(maxTemp)

        // Monitor cadence: process capture + anomaly detection (every 2 seconds)
        if tickCounter % monitorCadence == 0 {
            monitorTick(status: status, anomalyTemp: anomalyTemp)
        }

        // Safety override: any sensor > 95°C, unless the profile leaves fans to macOS.
        // Updated every tick, whatever the profile, so a profile switch keeps the window.
        let sustainedHot = safetyHeat.update(hot: maxTemp >= FanProfile.safetyTempThreshold, now: now)
        if activeProfile.safetyOverrideEngages(at: maxTemp, sustained: sustainedHot) {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                fanRamp.reset(to: 1)
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
            }
            if tickCounter % uiUpdateCadence == 0 {
                onUpdate?(status, activeProfile, state)
            }
            tickCounter += 1
            return
        }

        // Clear safety override with hysteresis
        if state == .safetyOverride
            && maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = .idle
        }

        // Sustained trigger: track consecutive ticks above start threshold.
        // Per-profile duration — converted to tick count at runtime.
        let startThreshold = activeProfile.curve.startTemp
        if controlTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        // Profile-specific logic
        if activeProfile.curve.adaptive != nil {
            tickAdaptive(status: status, peakTemp: controlTemp)
        } else {
            tickCurve(status: status, peakTemp: controlTemp)
        }

        // UI update at slower cadence (uiUpdateIntervalSec)
        if tickCounter % uiUpdateCadence == 0 {
            onUpdate?(status, activeProfile, state)
        }

        tickCounter += 1
    }

    // MARK: - Monitor Cadence (every 2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Runs at 2-second intervals to avoid sysctl overhead at 100ms.
    private func monitorTick(status: ThermalStatus, anomalyTemp: Float) {
        // Rolling process buffer — always capturing, like a security camera
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        // Anomaly detection: two tiers
        // Tier 1: instant spike — >5°C between consecutive readings (2 seconds)
        // Tier 2: sustained change — >10°C over 30 seconds
        if !isCalibrating {
            var spikeDetected = false

            // Tier 1: check against previous reading
            if let prevTemp = anomalyHistory.last {
                let instantDelta = anomalyTemp - prevTemp
                if abs(instantDelta) > 5 {
                    let direction = instantDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Instant \(direction): \(String(format: "%.1f", prevTemp))→\(String(format: "%.1f", anomalyTemp))°C " +
                        "(\(String(format: "%+.1f", instantDelta))°C in 2s) | " +
                        "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                        "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                }
            }

            // Tier 2: check over 30-second window
            if anomalyHistory.count >= 15 {
                let oldest = anomalyHistory.first!
                let sustainedDelta = anomalyTemp - oldest
                if abs(sustainedDelta) > 10 {
                    let direction = sustainedDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Sustained \(direction): \(String(format: "%.1f", oldest))→\(String(format: "%.1f", anomalyTemp))°C " +
                        "(\(String(format: "%+.1f", sustainedDelta))°C in 30s) | " +
                        "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                        "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                    anomalyHistory.removeAll()
                }
            }

            // Dump the rolling buffer on any spike — shows what was running BEFORE
            if spikeDetected {
                TFLogger.shared.info("Pre-spike process history (last \(processBuffer.count * 2)s):")
                for entry in processBuffer {
                    TFLogger.shared.info("  \(entry.timestamp): \(entry.processes)")
                }
            }
        }

        anomalyHistory.append(anomalyTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }
    }

    // MARK: - Adaptive (Smart-style) Profiles

    /// Smart's logic, driven by the active profile's curve and `adaptive` settings.
    /// Built-in Smart: stop 50°C, start 53°C, ceiling 85°C, 100% cap, S-curve, boost 0.2.
    /// `peakTemp` is the control temperature (smoothed when the profile asks for it).
    private func tickAdaptive(status: ThermalStatus, peakTemp: Float) {
        let curve = activeProfile.curve
        let name = activeProfile.name

        // Sample temperature history at monitor cadence (2s) for stable rate-of-change
        if tickCounter % monitorCadence == 0 {
            tempHistory.append(peakTemp)
            if tempHistory.count > 4 { tempHistory.removeFirst() }
        }

        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317
        let minPct = minRPM / maxRPM

        // Below stop threshold and fans running: turn off (with hysteresis)
        if peakTemp < curve.stopTemp && fansCurrentlyRunning && rateOfChange() <= 0 {
            applyCommand(.resetAuto)
            fanRamp.reset(to: 0)
            fansCurrentlyRunning = false
            state = .idle
            TFLogger.shared.fan("\(name) fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C")
            return
        }

        // Below start and fans not running: stay off (covers the stop–start hysteresis band)
        if peakTemp < curve.startTemp && !fansCurrentlyRunning {
            return
        }

        // Sustained trigger: per-profile duration
        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(name)]")
            }
            return
        }

        var targetPct = curve.adaptiveTargetPercent(at: peakTemp, rate: rateOfChange(),
                                                    calibration: calibration)

        // Enforce minimum RPM
        if targetPct > 0 && targetPct < minPct {
            targetPct = minPct
        }

        // Ramp governors — per-profile rates, per-tick amounts
        let rampUp = curve.rampUpPerSec * tickInterval
        let rampDown = curve.rampDownPerSec * tickInterval

        if let targetRPM = fanRamp.step(toward: targetPct, up: rampUp, down: rampDown, instant: false,
                                        minRPM: minRPM, maxRPM: maxRPM) {
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("\(name) fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C")
            }

            fansCurrentlyRunning = true
            state = .active(profileName: name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: name)
        }
    }

    /// Temperature rate of change in °C per second (smoothed over history).
    /// History is sampled at monitor cadence (2s), so this covers ~8 seconds.
    private func rateOfChange() -> Float {
        guard tempHistory.count >= 2 else { return 0 }
        let oldest = tempHistory.first!
        let newest = tempHistory.last!
        // tempHistory sampled at monitor cadence (2s intervals)
        let seconds = Float(tempHistory.count - 1) * Float(monitorCadence) * tickInterval
        return (newest - oldest) / seconds
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(status: ThermalStatus, peakTemp: Float) {
        let curve = activeProfile.curve
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        // Hands-off profiles (Silent): don't control fans, just monitor
        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                fanRamp.reset(to: 0)
                state = .idle
            }
            return
        }

        // Get target from curve (now applies curve shape: easeIn, linear, easeOut, sCurve)
        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            // Curve says fans should be off
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                fanRamp.reset(to: 0)
                state = .idle
                TFLogger.shared.fan("Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        // Sustained trigger: per-profile duration.
        // Converted to tick count at runtime based on tick interval.
        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")
            }
            return
        }

        // 0.001 signals "keep at minimum" (hysteresis band)
        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget

        // Clamp to valid range
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Ramp governors — per-profile rates, per-tick amounts
        let rampUp = curve.rampUpPerSec * tickInterval
        let rampDown = curve.rampDownPerSec * tickInterval

        // instantEngage skips the up governor; the down governor always applies.
        if let targetRPM = fanRamp.step(toward: targetPct, up: rampUp, down: rampDown,
                                        instant: curve.instantEngage, minRPM: minRPM, maxRPM: maxRPM) {
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            fansCurrentlyRunning = true
            state = .active(profileName: activeProfile.name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: activeProfile.name)
        }
    }

    // MARK: - Process Capture

    /// Mach absolute time units → nanoseconds (125/3 on Apple Silicon, 1/1 on Intel).
    private static let machTimebase: mach_timebase_info = {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return timebase
    }()

    /// Capture top 5 processes by CPU for anomaly logging. Without root only the user's own
    /// processes are readable, so root daemons (mds_stores, backupd, …) never appear.
    private func captureTopProcesses() -> String {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return "unavailable" }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)   // room for processes started since
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return "unavailable" }

        let timebase = Self.machTimebase
        var info = proc_taskinfo()
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        var samples: [ProcessCPUSample] = []

        for pid in pids.prefix(Int(listed)) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize,
                  proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let cpuNs = (info.pti_total_user + info.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
            samples.append(ProcessCPUSample(pid: pid, name: String(cString: nameBuffer), cpuNs: cpuNs))
        }
        return processCPU.update(samples, at: DispatchTime.now().uptimeNanoseconds)
    }

    // MARK: - Helpers

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }

}
