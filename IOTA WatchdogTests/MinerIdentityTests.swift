//
//  MinerIdentityTests.swift
//  IOTA WatchdogTests
//
//  The hotkey used to be hardcoded, so a copy given to someone else reported the author's miner
//  rather than theirs. These cover detection, and the cases where guessing must be refused.
//

import XCTest
@testable import IOTA_Watchdog

final class MinerIdentityTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a wallet hotkey pair in the layout Bittensor uses, including the private fields
    /// that must never be read.
    private func makeHotkey(wallet: String, name: String, address: String) throws {
        let directory = root.appendingPathComponent(wallet).appendingPathComponent("hotkeys")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = """
        {"accountId":"0xabc","publicKey":"0xabc","secretPhrase":"never read this",\
        "secretSeed":"never read this","ss58Address":"\(address)"}
        """
        try body.write(to: directory.appendingPathComponent(name),
                       atomically: true, encoding: .utf8)
        try body.write(to: directory.appendingPathComponent("\(name)pub.txt"),
                       atomically: true, encoding: .utf8)
    }

    func testDetectsTheIOTAWalletHotkey() throws {
        try makeHotkey(wallet: "iota", name: "iota_miner",
                       address: "5TESTAAATestMinerAaaaTestMinerAaaaTestMinerAaaaT")
        let found = try XCTUnwrap(MinerIdentity.detect(in: root))
        XCTAssertEqual(found.prefix, "5TESTAAA")
        XCTAssertEqual(found.wallet, "iota")
        XCTAssertEqual(found.name, "iota_miner")
    }

    /// The point of the whole change: a different Mac reports its own miner.
    func testDetectsADifferentMachinesHotkey() throws {
        try makeHotkey(wallet: "iota", name: "iota_miner",
                       address: "5TESTBBBTestMinerBbbbTestMinerBbbbTestMinerBbbbT")
        XCTAssertEqual(MinerIdentity.detect(in: root)?.prefix, "5TESTBBB")
    }

    /// A single hotkey under an unexpected wallet name is still unambiguous.
    func testFallsBackToTheOnlyHotkeyPresent() throws {
        try makeHotkey(wallet: "mywallet", name: "somekey",
                       address: "5TESTDDDTestMinerDdddTestMinerDdddTestMinerDdddT")
        XCTAssertEqual(MinerIdentity.detect(in: root)?.prefix, "5TESTDDD")
    }

    /// Two unrelated wallets and no expected name: refuse rather than pick one at random.
    /// Guessing here is exactly the bug we found in the IOTA app itself.
    func testRefusesToGuessBetweenSeveralHotkeys() throws {
        try makeHotkey(wallet: "walletA", name: "keyA",
                       address: "5AAAAAAAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        try makeHotkey(wallet: "walletB", name: "keyB",
                       address: "5BBBBBBBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertNil(MinerIdentity.detect(in: root))
    }

    /// The expected wallet wins even when others are present.
    func testPrefersTheIOTAWalletOverOthers() throws {
        try makeHotkey(wallet: "walletA", name: "keyA",
                       address: "5AAAAAAAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        try makeHotkey(wallet: "iota", name: "iota_miner",
                       address: "5TESTAAATestMinerAaaaTestMinerAaaaTestMinerAaaaT")
        XCTAssertEqual(MinerIdentity.detect(in: root)?.prefix, "5TESTAAA")
    }

    func testNoWalletsAtAllYieldsNothing() {
        XCTAssertNil(MinerIdentity.detect(in: root))
        XCTAssertTrue(MinerIdentity.availableHotkeys(in: root).isEmpty)
    }

    /// The same hotkey is stored twice on disk; it must be reported once.
    func testTheSidecarDoesNotProduceADuplicate() throws {
        try makeHotkey(wallet: "iota", name: "iota_miner",
                       address: "5TESTAAATestMinerAaaaTestMinerAaaaTestMinerAaaaT")
        XCTAssertEqual(MinerIdentity.availableHotkeys(in: root).count, 1)
    }

    /// Fallback for a machine with no readable wallet: take it from the registration line.
    func testPrefixFromTheMinersLog() {
        let events = [
            LogEvent(timestamp: Date(), kind: .chatter, rawLine: ""),
            LogEvent(timestamp: Date(), kind: .registered(prefix: "5TESTCCC"), rawLine: "")
        ]
        XCTAssertEqual(MinerIdentity.prefixFromLog(events), "5TESTCCC")
        XCTAssertNil(MinerIdentity.prefixFromLog([]))
    }
}

@MainActor
final class WatchedMinerSettingsTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// A typed hotkey overrides detection, and clearing it returns to automatic.
    func testOverrideWinsAndCanBeCleared() {
        let settings = WatchdogSettings(fileURL: fileURL)
        settings.localPrefixOverride = "5TESTBBB"
        XCTAssertEqual(settings.localPrefix, "5TESTBBB")
        XCTAssertEqual(settings.engineConfig.localPrefix, "5TESTBBB")

        settings.localPrefixOverride = ""
        XCTAssertEqual(settings.localPrefix, settings.detectedHotkey?.prefix)
    }

    func testWhitespaceOnlyOverrideIsTreatedAsAutomatic() {
        let settings = WatchdogSettings(fileURL: fileURL)
        settings.localPrefixOverride = "   "
        XCTAssertEqual(settings.localPrefix, settings.detectedHotkey?.prefix,
                       "blank input must not be treated as a real prefix")
    }

    /// An empty prefix would match the first miner the API returns, so it must never be used.
    func testPrefixIsNeverEmpty() {
        let settings = WatchdogSettings(fileURL: fileURL)
        settings.localPrefixOverride = ""
        if let prefix = settings.localPrefix {
            XCTAssertFalse(prefix.isEmpty)
        }
    }

    func testOverrideSurvivesARelaunch() {
        let first = WatchdogSettings(fileURL: fileURL)
        first.localPrefixOverride = "5TESTCCC"
        let second = WatchdogSettings(fileURL: fileURL)
        XCTAssertEqual(second.localPrefix, "5TESTCCC")
    }
}
