//
//  MinerIdentity.swift
//  IOTA Watchdog
//
//  Works out which miner is running on *this* Mac.
//
//  The hotkey was originally hardcoded, which meant a copy given to someone else reported the
//  original author's miner instead of theirs. It is now read from the machine.
//
//  Two sources, in order of reliability:
//    1. The Bittensor wallet on disk — present whether or not the miner is running.
//    2. The miner's own log, which names the hotkey when it registers.
//
//  Only the `ss58Address` field is ever read from a wallet file. Those files also hold private
//  key material (`secretPhrase`, `secretSeed`); nothing else is decoded, kept or logged.
//

import Foundation

enum MinerIdentity {

    /// Where Bittensor keeps wallets.
    static var walletsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bittensor/wallets")
    }

    /// A hotkey found on this machine.
    struct Hotkey: Equatable {
        /// Full ss58 address.
        let address: String
        /// Wallet folder name, e.g. "iota".
        let wallet: String
        /// Hotkey file name, e.g. "iota_miner".
        let name: String

        /// The 8-character prefix the dashboard and the API search by.
        var prefix: String { String(address.prefix(8)) }
    }

    /// The wallet the IOTA app creates by default.
    private static let preferredWallet = "iota"
    private static let preferredHotkey = "iota_miner"

    /// Only field read out of a wallet file. The rest of the file is ignored on purpose.
    private struct PublicKeyOnly: Decodable {
        let ss58Address: String?
    }

    /// Every hotkey found under the wallets directory.
    static func availableHotkeys(in directory: URL? = nil) -> [Hotkey] {
        let root = directory ?? walletsDirectory
        let manager = FileManager.default
        guard let wallets = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }

        var found: [Hotkey] = []
        for wallet in wallets.sorted() {
            let hotkeyDirectory = root.appendingPathComponent(wallet)
                .appendingPathComponent("hotkeys")
            guard let files = try? manager.contentsOfDirectory(atPath: hotkeyDirectory.path) else {
                continue
            }
            // A hotkey is stored twice: "<name>" and the public sidecar "<name>pub.txt".
            // Prefer the sidecar, and never surface the same hotkey twice.
            let names = Set(files.map { $0.hasSuffix("pub.txt")
                ? String($0.dropLast("pub.txt".count))
                : $0 })

            for name in names.sorted() {
                let candidates = ["\(name)pub.txt", name]
                for candidate in candidates {
                    let url = hotkeyDirectory.appendingPathComponent(candidate)
                    guard let data = try? Data(contentsOf: url),
                          let decoded = try? JSONDecoder().decode(PublicKeyOnly.self, from: data),
                          let address = decoded.ss58Address, !address.isEmpty else { continue }
                    found.append(Hotkey(address: address, wallet: wallet, name: name))
                    break
                }
            }
        }
        return found
    }

    /// The hotkey this Mac is most likely mining with.
    ///
    /// Prefers the IOTA app's own wallet and hotkey names. Falls back to the only hotkey present.
    /// Returns nil when there is none, or when several exist and none is the expected one — an
    /// arbitrary guess would be worse than admitting we do not know.
    static func detect(in directory: URL? = nil) -> Hotkey? {
        let hotkeys = availableHotkeys(in: directory)
        if let expected = hotkeys.first(where: {
            $0.wallet == preferredWallet && $0.name == preferredHotkey
        }) {
            return expected
        }
        if let onlyOne = hotkeys.first, hotkeys.count == 1 { return onlyOne }
        if let inPreferredWallet = hotkeys.first(where: { $0.wallet == preferredWallet }),
           hotkeys.filter({ $0.wallet == preferredWallet }).count == 1 {
            return inPreferredWallet
        }
        return nil
    }

    /// Last resort: the prefix the miner logged when it registered, e.g.
    /// "✅ Miner 5TESTAAA registered successfully in layer 1 on training epoch 55".
    /// Only used when no wallet is readable.
    static func prefixFromLog(_ events: [LogEvent]) -> String? {
        for event in events.reversed() {
            if case .registered(let prefix) = event.kind, !prefix.isEmpty {
                return prefix
            }
        }
        return nil
    }
}
