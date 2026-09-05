//
//  AppLinks.swift
//  IOTA Watchdog
//
//  Outward-facing links, kept in one place.
//

import Foundation

enum AppLinks {

    struct DonationLink: Identifiable {
        let label: String
        let url: URL
        /// The service's brand colour, as 0xRRGGBB. Kept as a number so this file stays
        /// Foundation-only; the view turns it into a Color.
        let brand: UInt32
        /// Brand colours differ wildly in brightness, so each link says whether its label
        /// should be dark. White on Buy Me a Coffee's yellow is unreadable.
        let usesDarkLabel: Bool
        /// Asset-catalogue name of the service's own logo, when we have it. Nil just means
        /// the button shows its label alone.
        let iconAsset: String?
        var id: String { url.absoluteString }
    }

    /// Ways to say thanks. Shown in the menu; an empty list hides that row entirely.
    ///
    /// Built with `compactMap` rather than force-unwrapping, so a typo in a literal drops the
    /// one bad link instead of crashing the app on launch.
    static let donations: [DonationLink] = [
        ("Ko-fi", "https://ko-fi.com/monit", UInt32(0xFF5E5B), false, nil),
        ("Buy Me a Coffee", "https://buymeacoffee.com/le_monit", UInt32(0xFFDD00), true, "BMCIcon")
    ].compactMap { label, string, brand, darkLabel, icon -> DonationLink? in
        URL(string: string).map {
            DonationLink(label: label, url: $0, brand: brand,
                         usesDarkLabel: darkLabel, iconAsset: icon)
        }
    }

    /// Project home, used by "Report an issue".
    static let repository = URL(string: "https://github.com/Ronan-Le-Monit/IOTA-Miner-Watchdog")
}
