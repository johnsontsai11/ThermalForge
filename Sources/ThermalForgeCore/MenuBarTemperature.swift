//
//  MenuBarTemperature.swift
//  ThermalForge
//
//  The temperature the menu bar label shows.
//

import Foundation

/// The hottest CPU/GPU sensor averaged over the last `samples` readings. The raw peak
/// jumps ~20°C for 1–2 s every few seconds on a Mac mini M4 (Tp0W), and every change of
/// the displayed degree redraws the status item — most of the app's idle CPU.
public struct MenuBarTemperature {
    private var average: RollingAverage
    private var shown: Float?

    public init(samples: Int) {
        average = RollingAverage(capacity: samples)
    }

    /// Add the raw CPU/GPU peak (°C). Returns the averaged temperature to show when the
    /// label's displayed whole degrees change, in °C or °F; nil when it wouldn't change.
    public mutating func add(_ peakC: Float) -> Float? {
        let averaged = average.add(peakC)
        guard Self.displayedDegrees(averaged) != shown.map(Self.displayedDegrees) else { return nil }
        shown = averaged
        return averaged
    }

    /// The whole degrees the label shows for `tempC`, in both units, so a stored value is
    /// never stale in whichever unit the user switches to.
    private static func displayedDegrees(_ tempC: Float) -> [Int] {
        [Int(tempC), Int(tempC * 9 / 5 + 32)]
    }
}
