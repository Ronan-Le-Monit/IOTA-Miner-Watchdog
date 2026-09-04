//
//  IOTA_WatchdogApp.swift
//  IOTA Watchdog
//
//  Menu-bar-only app (LSUIElement) that watches the local IOTA miner and restarts it
//  when it stops, freezes or stops making progress.
//

import SwiftUI

@main
struct IOTA_WatchdogApp: App {
    var body: some Scene {
        MenuBarExtra("IOTA Watchdog", systemImage: "cube.transparent") {
            // Replaced by MenuView once the engine lands.
            Text("IOTA Watchdog")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}
