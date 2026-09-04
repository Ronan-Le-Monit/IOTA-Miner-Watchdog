//
//  WatchdogSettings.swift
//  IOTA Watchdog
//
//  User-facing settings, persisted in UserDefaults. Thresholds live in WatchdogConfig; this
//  type owns the ones the user can change and hands the engine a config built from them.
//

import Foundation
import Combine
import ServiceManagement

@MainActor
final class WatchdogSettings: ObservableObject {

    private enum Key {
        static let autoRestart = "autoRestartEnabled"
        static let keepAwake = "keepAwakeEnabled"
        static let localPrefix = "localPrefix"
        static let noProgressMinutes = "noProgressMinutes"
        static let frozenMinutes = "frozenMinutes"
        static let countdownSeconds = "confirmationCountdownSeconds"
        static let notify = "notificationsEnabled"
    }

    @Published var autoRestartEnabled: Bool {
        didSet { defaults.set(autoRestartEnabled, forKey: Key.autoRestart) }
    }
    @Published var keepAwakeEnabled: Bool {
        didSet { defaults.set(keepAwakeEnabled, forKey: Key.keepAwake) }
    }
    @Published var localPrefix: String {
        didSet { defaults.set(localPrefix, forKey: Key.localPrefix) }
    }
    @Published var noProgressMinutes: Int {
        didSet { defaults.set(noProgressMinutes, forKey: Key.noProgressMinutes) }
    }
    @Published var frozenMinutes: Int {
        didSet { defaults.set(frozenMinutes, forKey: Key.frozenMinutes) }
    }
    @Published var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: Key.countdownSeconds) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notify) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            // Deliberately off on first run: this app force-quits and relaunches another app, so
            // the user should switch it on knowingly and watch the first restart. One toggle away
            // in the menu.
            Key.autoRestart: false,
            Key.keepAwake: true,
            Key.localPrefix: "5DXDN2UR",
            Key.noProgressMinutes: 60,
            Key.frozenMinutes: 5,
            Key.countdownSeconds: 60,
            Key.notify: true
        ])
        autoRestartEnabled = defaults.bool(forKey: Key.autoRestart)
        keepAwakeEnabled = defaults.bool(forKey: Key.keepAwake)
        localPrefix = defaults.string(forKey: Key.localPrefix) ?? "5DXDN2UR"
        noProgressMinutes = defaults.integer(forKey: Key.noProgressMinutes)
        frozenMinutes = defaults.integer(forKey: Key.frozenMinutes)
        countdownSeconds = defaults.integer(forKey: Key.countdownSeconds)
        notificationsEnabled = defaults.bool(forKey: Key.notify)
    }

    /// The engine configuration implied by these settings.
    var engineConfig: WatchdogConfig {
        var config = WatchdogConfig()
        config.autoRestartEnabled = autoRestartEnabled
        config.localPrefix = localPrefix
        config.noProgressThreshold = TimeInterval(noProgressMinutes * 60)
        config.frozenThreshold = TimeInterval(frozenMinutes * 60)
        config.confirmationCountdown = TimeInterval(countdownSeconds)
        return config
    }

    // MARK: Launch at login

    /// Whether the app is registered to start at login.
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item. Returns the error text on failure.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
