//
//  IOTA_WatchdogApp.swift
//  IOTA Watchdog
//
//  Menu-bar app (LSUIElement) that watches the local IOTA miner and restarts it when it
//  stops, crashes, freezes or stops making progress.
//

import SwiftUI
import AppKit

/// Starts the watchdog at launch and owns the fallback window.
///
/// Starting must not be tied to the menu's `onAppear`: a MenuBarExtra only builds its content
/// when the user opens it, so the watchdog would sit idle until someone clicked the icon.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusWindow = StatusWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let coordinator = WatchdogCoordinator.shared
            coordinator.start()

            // First ever launch: show the window, otherwise the user has no way of telling the
            // app started at all if the menu bar has no room for its icon.
            if statusWindow.isFirstLaunch {
                statusWindow.markWelcomed()
                statusWindow.show(coordinator: coordinator)
            }
        }
    }

    /// Opening the app again (double-click in Finder, or the Dock) brings the window back rather
    /// than doing nothing, which is what an agent app would otherwise appear to do.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            statusWindow.show(coordinator: WatchdogCoordinator.shared)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WatchdogCoordinator.shared.stop() }
    }
}

@main
struct IOTA_WatchdogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let coordinator = WatchdogCoordinator.shared
    /// Observed explicitly: the state lives on the engine, so observing only the coordinator
    /// left the menu bar icon frozen on its launch value.
    @ObservedObject private var engine = WatchdogCoordinator.shared.engine

    var body: some Scene {
        MenuBarExtra {
            MenuView(coordinator: coordinator,
                     settings: coordinator.settings,
                     engine: engine,
                     power: coordinator.power)
        } label: {
            Image(systemName: engine.state.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
