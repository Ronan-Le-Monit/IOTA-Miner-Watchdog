//
//  WatchdogSettings.swift
//  IOTA Watchdog
//
//  User-facing settings.
//
//  Stored as JSON in Application Support rather than UserDefaults: a stale sandbox container
//  left by the project template intercepts this bundle's preference domain, so UserDefaults
//  writes did not survive a relaunch (the app read an empty domain on every launch and silently
//  fell back to the registered defaults). Plain file I/O is unaffected and is what the log and
//  the first-launch marker already use.
//
//  Launch arguments still override any stored value, which keeps `-autoRestartEnabled NO`
//  usable for testing.
//

import Foundation
import Combine
import ServiceManagement

@MainActor
final class WatchdogSettings: ObservableObject {

    /// The persisted shape. Optional fields so an older file still loads.
    private struct Stored: Codable {
        var autoRestartEnabled: Bool?
        var keepAwakeEnabled: Bool?
        var localPrefixOverride: String?
        var noProgressMinutes: Int?
        var frozenMinutes: Int?
        var countdownSeconds: Int?
        var notificationsEnabled: Bool?
        var noProgressRuleEnabled: Bool?
        var resetLoopRuleEnabled: Bool?
        var holdForRunStateEnabled: Bool?
    }

    @Published var autoRestartEnabled: Bool { didSet { save() } }
    @Published var keepAwakeEnabled: Bool { didSet { save() } }
    /// Empty means "work it out from this Mac". Set only when the user types one in.
    @Published var localPrefixOverride: String { didSet { save() } }
    /// The hotkey found on this machine, re-read at launch so it is never stale.
    @Published private(set) var detectedHotkey: MinerIdentity.Hotkey?
    @Published var noProgressMinutes: Int { didSet { save() } }
    @Published var frozenMinutes: Int { didSet { save() } }
    @Published var countdownSeconds: Int { didSet { save() } }
    @Published var notificationsEnabled: Bool { didSet { save() } }
    /// Optional rules, off by default. See `WatchdogConfig` for why.
    @Published var noProgressRuleEnabled: Bool { didSet { save() } }
    @Published var resetLoopRuleEnabled: Bool { didSet { save() } }
    @Published var holdForRunStateEnabled: Bool { didSet { save() } }

    private let fileURL: URL
    /// Suppresses saving while the initial values are being assigned.
    private var isLoading = true

    init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IOTA Watchdog/settings.json")
        self.fileURL = url

        let stored: Stored
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }

        // Auto-restart is off until the user asks for it: this app force-quits and relaunches
        // another app, so that should be a deliberate choice.
        autoRestartEnabled = stored.autoRestartEnabled ?? false
        keepAwakeEnabled = stored.keepAwakeEnabled ?? true
        localPrefixOverride = stored.localPrefixOverride ?? ""
        detectedHotkey = MinerIdentity.detect()
        noProgressMinutes = stored.noProgressMinutes ?? 60
        frozenMinutes = stored.frozenMinutes ?? 5
        countdownSeconds = stored.countdownSeconds ?? 60
        notificationsEnabled = stored.notificationsEnabled ?? true
        noProgressRuleEnabled = stored.noProgressRuleEnabled ?? false
        resetLoopRuleEnabled = stored.resetLoopRuleEnabled ?? false
        holdForRunStateEnabled = stored.holdForRunStateEnabled ?? false

        applyLaunchArgumentOverrides()
        isLoading = false
    }

    /// Command-line overrides win over the stored file, for testing.
    private func applyLaunchArgumentOverrides() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        func bool(_ key: String) -> Bool? {
            guard let raw = arguments[key] else { return nil }
            if let value = raw as? Bool { return value }
            if let value = raw as? String { return (value as NSString).boolValue }
            if let value = raw as? NSNumber { return value.boolValue }
            return nil
        }
        if let value = bool("autoRestartEnabled") { autoRestartEnabled = value }
        if let value = bool("keepAwakeEnabled") { keepAwakeEnabled = value }
        if let value = bool("noProgressRuleEnabled") { noProgressRuleEnabled = value }
        if let value = bool("resetLoopRuleEnabled") { resetLoopRuleEnabled = value }
        if let value = bool("holdForRunStateEnabled") { holdForRunStateEnabled = value }
        if let value = arguments["localPrefix"] as? String { localPrefixOverride = value }
    }

    private func save() {
        guard !isLoading else { return }
        let stored = Stored(autoRestartEnabled: autoRestartEnabled,
                            keepAwakeEnabled: keepAwakeEnabled,
                            localPrefixOverride: localPrefixOverride,
                            noProgressMinutes: noProgressMinutes,
                            frozenMinutes: frozenMinutes,
                            countdownSeconds: countdownSeconds,
                            notificationsEnabled: notificationsEnabled,
                            noProgressRuleEnabled: noProgressRuleEnabled,
                            resetLoopRuleEnabled: resetLoopRuleEnabled,
                            holdForRunStateEnabled: holdForRunStateEnabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Where the settings file lives, for diagnostics.
    var storageURL: URL { fileURL }

    /// The miner to watch: the user's override if they set one, otherwise whatever this Mac has.
    /// Nil means we could not identify a miner, which must be reported rather than guessed — an
    /// empty prefix would match the first miner in the API and show a stranger's numbers.
    var localPrefix: String? {
        let trimmed = localPrefixOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return detectedHotkey?.prefix
    }

    /// Re-runs detection, e.g. after the user installs a wallet.
    func refreshDetectedHotkey() {
        detectedHotkey = MinerIdentity.detect()
    }

    /// The engine configuration implied by these settings.
    var engineConfig: WatchdogConfig {
        var config = WatchdogConfig()
        config.autoRestartEnabled = autoRestartEnabled
        config.localPrefix = localPrefix
        config.noProgressThreshold = TimeInterval(noProgressMinutes * 60)
        config.frozenThreshold = TimeInterval(frozenMinutes * 60)
        config.confirmationCountdown = TimeInterval(countdownSeconds)
        config.noProgressRuleEnabled = noProgressRuleEnabled
        config.resetLoopRuleEnabled = resetLoopRuleEnabled
        config.holdForRunStateEnabled = holdForRunStateEnabled
        return config
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

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
