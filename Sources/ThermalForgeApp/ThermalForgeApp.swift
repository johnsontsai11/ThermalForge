//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import SwiftUI
import ThermalForgeCore

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reset fans on quit so the daemon doesn't hold stale APP settings — but
        // ONLY if the app owns the hold. A CLI hold (`sudo thermalforge max`) is the
        // user's deliberate, unsupervised choice; quitting the menu bar app must not
        // destroy it — that's the v0.1.7 arbitration feature. Synchronous on purpose:
        // the process is exiting, so an async write would be dropped; both calls are
        // bounded by the sendRaw timeout.
        let client = DaemonClient()
        if let state = try? client.readState(), state.owner == "app" {
            _ = try? client.execute(.resetAuto)
        }
        // owner == "cli" → leave the CLI hold alone; owner == "none" → nothing to reset.
    }
}

@main
struct ThermalForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(
                state: appState.monitorState,
                maxTemp: appState.maxTemp,
                fahrenheit: appState.useFahrenheit,
                needsDaemonUpdate: appState.daemonVersionMismatch != nil
            )
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: MonitorState
    let maxTemp: Float?
    var fahrenheit: Bool = false
    var needsDaemonUpdate: Bool = false

    /// The whole label as one template image. The menu bar redraws a label's Text in its own
    /// proportional font (ignoring `.monospaced` and `.monospacedDigit()`), so "61°" was 2 pt
    /// narrower than "62°" and each such change shifted every item to its left. It also takes
    /// only one image from a label, so icon and degrees are rendered together.
    var body: some View {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true // tinted by the menu bar for light and dark
        return Image(nsImage: image)
    }

    private var content: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .overlay(alignment: .topTrailing) {
                    // Small dot when the daemon is out of sync — visible without
                    // opening the menu, for users who never touch the CLI.
                    if needsDaemonUpdate {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
            if let tempC = maxTemp {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                Text("\(Int(display))°")
            }
        }
        // The size and font the menu bar drew the old Text label and symbol in, with
        // fixed-width digits so every two-digit reading is the same width.
        .font(.system(size: NSFont.menuBarFont(ofSize: 0).pointSize).monospacedDigit())
    }

    private var iconName: String {
        switch state {
        case .safetyOverride: return "exclamationmark.triangle.fill"
        case .active: return "fan.fill"
        case .idle: return "fan"
        }
    }
}
