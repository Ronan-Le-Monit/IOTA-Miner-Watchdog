//
//  StatusWindow.swift
//  IOTA Watchdog
//
//  A real window showing the same content as the menu.
//
//  Why an agent app needs one: the only visible sign of a MenuBarExtra app is its menu bar icon,
//  and macOS silently drops status items when the menu bar runs out of room — which it does
//  easily on a notched MacBook Pro with a few menu bar apps already installed. Without this
//  window a running watchdog looks identical to one that never launched.
//
//  Shown on first launch and whenever the user opens the app again from Finder or the Dock.
//

import SwiftUI
import AppKit

@MainActor
final class StatusWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    /// Marker file recording that the window has been shown once. Kept as a file rather than in
    /// UserDefaults because preferences do not persist reliably for this bundle (a stale sandbox
    /// container intercepts them), while file writes work.
    private var welcomeMarker: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IOTA Watchdog/.welcomed")
    }

    /// True the first time this app ever runs for this user.
    var isFirstLaunch: Bool {
        !FileManager.default.fileExists(atPath: welcomeMarker.path)
    }

    func markWelcomed() {
        let directory = welcomeMarker.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: welcomeMarker)
    }

    /// Brings the window up, creating it if needed, and focuses the app so it is actually seen.
    func show(coordinator: WatchdogCoordinator) {
        if window == nil {
            let hosting = NSHostingView(
                rootView: StatusWindowView(coordinator: coordinator,
                                           settings: coordinator.settings,
                                           engine: coordinator.engine,
                                           power: coordinator.power))
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            created.title = "IOTA Watchdog"
            created.contentView = hosting
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        // A window in an agent app needs a regular activation policy to take focus. It is put
        // back to .accessory on close, so the app does not keep a Dock icon and a Cmd-Tab entry
        // for the rest of the session.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The window's content: the menu, plus a line explaining where to find the app again.
private struct StatusWindowView: View {
    @ObservedObject var coordinator: WatchdogCoordinator
    @ObservedObject var settings: WatchdogSettings
    @ObservedObject var engine: WatchdogEngine
    @ObservedObject var power: PowerMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MenuView(coordinator: coordinator,
                         settings: settings,
                         engine: engine,
                         power: power)
                Text("The watchdog keeps running when you close this window. "
                     + "Look for the cube in the menu bar, or open IOTA Watchdog again to bring "
                     + "this window back.")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 360)
        .background(Theme.background)
    }
}
