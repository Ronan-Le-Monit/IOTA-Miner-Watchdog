//
//  PowerMonitor.swift
//  IOTA Watchdog
//
//  System sleep is the dominant cause of "the miner stopped mining" on this Mac.
//  Measured on 2026-09-04: `pmset -g custom` reports `sleep 1` on both AC and battery, so the
//  machine sleeps about a minute after the display turns off. Five sleep episodes between 10:00
//  and 15:00 that day; each froze the worker, got it kicked from the run, and cost ~6 minutes of
//  re-registration on wake.
//
//  Two jobs here:
//    • report when the Mac last woke, so the engine can hold off judging a just-woken miner
//    • hold a power assertion while the miner is training, so the Mac stops sleeping at all
//

import Foundation
import Combine
import AppKit
import IOKit.pwr_mgt

/// Observes sleep/wake and can prevent idle sleep.
@MainActor
final class PowerMonitor: ObservableObject {

    /// When the Mac last woke from sleep. Nil until a wake happens in this session.
    @Published private(set) var lastWakeAt: Date?
    /// When the Mac last went to sleep, for display.
    @Published private(set) var lastSleepAt: Date?
    /// True while a keep-awake assertion is held.
    @Published private(set) var isHoldingSleepAssertion = false

    private var assertionID: IOPMAssertionID = 0
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastSleepAt = Date() }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastWakeAt = Date() }
        })
    }

    deinit {
        // Release the assertion if we still hold one; the ID is valid across isolation here.
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }

    /// How long ago the Mac woke, or nil if it has not slept during this session.
    var timeSinceWake: TimeInterval? {
        lastWakeAt.map { Date().timeIntervalSince($0) }
    }

    // MARK: Keep awake

    /// Prevents idle system sleep while the miner is training. The display may still turn off;
    /// only the machine sleeping is prevented. Equivalent to `caffeinate -i`.
    ///
    /// Note this cannot defeat a closed lid (unless the Mac is in clamshell mode) nor a thermal
    /// emergency sleep — one of those was logged at 14:32 on 2026-09-04.
    func setKeepAwake(_ enabled: Bool) {
        guard enabled != isHoldingSleepAssertion else { return }

        if enabled {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "IOTA miner is training" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                isHoldingSleepAssertion = true
            }
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID) }
            assertionID = 0
            isHoldingSleepAssertion = false
        }
    }

    // MARK: Diagnostics

    /// The system's idle-sleep timers, read from `pmset -g custom`, so the menu can warn when the
    /// Mac is configured to sleep almost immediately. Returns minutes for AC and battery;
    /// 0 means "never".
    static func idleSleepMinutes() -> (ac: Int?, battery: Int?) {
        let output = ProcessProbe.runCommand("/usr/bin/pmset", ["-g", "custom"])
        var battery: Int?
        var ac: Int?
        var inACSection = false

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery Power") { inACSection = false; continue }
            if line.hasPrefix("AC Power") { inACSection = true; continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "sleep", let value = Int(parts[1]) else { continue }
            if inACSection { ac = value } else { battery = value }
        }
        return (ac, battery)
    }
}
