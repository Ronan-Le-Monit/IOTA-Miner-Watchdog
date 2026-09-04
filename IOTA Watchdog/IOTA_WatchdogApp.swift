//
//  IOTA_WatchdogApp.swift
//  IOTA Watchdog
//
//  Menu-bar-only app (LSUIElement) that watches the local IOTA miner and restarts it when it
//  stops, crashes, freezes or stops making progress.
//

import SwiftUI
import AppKit

/// Starts the watchdog as soon as the app launches.
///
/// This must not be tied to the menu's `onAppear`: a MenuBarExtra's content is only built when
/// the user opens it, so the watchdog would sit idle until someone clicked the icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            WatchdogCoordinator.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            WatchdogCoordinator.shared.stop()
        }
    }
}

@main
struct IOTA_WatchdogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var coordinator = WatchdogCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(coordinator: coordinator,
                     settings: coordinator.settings,
                     engine: coordinator.engine,
                     power: coordinator.power)
        } label: {
            Image(systemName: coordinator.engine.state.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
