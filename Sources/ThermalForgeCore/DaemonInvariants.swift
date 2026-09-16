//
//  DaemonInvariants.swift
//  ThermalForge
//
//  Pure, hardware-free decision logic for the Phase 3 daemon-enforced invariants:
//  a token-bucket rate limiter for SMC-writing verbs, and the thermal-safety-floor
//  state decision. Both take injected inputs (a clock, a temperature) so they unit
//  test without a bound socket or SMC. The DaemonServer performs the actual SMC and
//  state effects; these types only decide.
//

import Foundation

/// Token-bucket rate limiter for the daemon's SMC-writing verbs (`max`/`set`/`setfan`
/// — `auto`/reset is exempt). Burst capacity absorbs a legitimate pump ramp (~10/s,
/// coalescing under backpressure) while a flood drains it to the refill rate and gets
/// `rateLimited`. The clock is injected so the boundary is testable without waiting.
public struct RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var last: Date

    public init(capacity: Double = 20, refillPerSecond: Double = 10, now: Date) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.last = now
    }

    /// Refill for elapsed time, then consume one token if available.
    public mutating func allow(now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(last))
        last = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// The thermal safety floor's decision, given a sampled temperature and the current
/// hold/suspension state. Thresholds are mirrored from `FanProfile` (read, not
/// invented). The DaemonServer maps `.engage`/`.restore` onto SMC + `safetySuspended`.
public struct ThermalFloor {
    public let threshold: Float
    public let clearBelow: Float

    public init(threshold: Float = FanProfile.safetyTempThreshold,
                hysteresis: Float = FanProfile.hysteresisDegrees) {
        self.threshold = threshold
        self.clearBelow = threshold - hysteresis
    }

    public enum Action: Equatable {
        case none
        case engage    // overheating while a below-max hold is active → override to max
        case restore   // cooled below the hysteresis point → restore the hold (or auto)
    }

    /// - sustained: has `temp` stayed at/above the threshold for `FanProfile.safetySustainSec`?
    /// - suspended: is the floor currently overriding fans to max?
    /// - holdCommand: the active hold's command string, or nil for auto / no hold.
    public func evaluate(temp: Float, sustained: Bool, holdCommand: String?, suspended: Bool) -> Action {
        // A bogus post-wake reading must not look "cooled" and release the override.
        guard FanProfile.isPlausibleTemp(temp) else { return .none }
        if suspended {
            // Restore only once cooled past the hysteresis point; otherwise keep max.
            return temp < clearBelow ? .restore : .none
        }
        // Engage only when overheating (sustained, so a brief sensor jump doesn't count)
        // AND a hold pins fans below max. No hold (auto) or an already-max hold needs
        // no override.
        guard temp >= threshold, sustained, let cmd = holdCommand, cmd != "max" else { return .none }
        return .engage
    }
}

/// Whether the peak has stayed at/above the safety threshold for `FanProfile.safetySustainSec`
/// straight. On the Mac mini M4 under load, Tp0W alone jumps past 95°C for 1–2 SMC updates
/// (~1 s each) while the other sensors stay ≤94°C; real overheating stays. The clock is
/// injected, so the monitor (200ms ticks) and the daemon floor (1 s) share the rule.
public struct SustainedHeat {
    /// Readings further apart than this aren't continuous: a daemon that wasn't sampling
    /// (no hold) or a run of failed reads restarts the count rather than bridging it.
    static let maxSampleGap: TimeInterval = 2.5

    private var hotSince: Date?
    private var lastSample: Date?

    public init() {}

    public mutating func update(hot: Bool, now: Date) -> Bool {
        let continuous = lastSample.map { now.timeIntervalSince($0) <= Self.maxSampleGap } ?? false
        lastSample = now
        guard hot else { hotSince = nil; return false }
        if hotSince == nil || !continuous { hotSince = now }
        return now.timeIntervalSince(hotSince ?? now) >= FanProfile.safetySustainSec
    }
}
