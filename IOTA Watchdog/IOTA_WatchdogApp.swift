//
//  IOTA_WatchdogApp.swift
//  IOTA Watchdog
//
//  Created by Ronan Leboudec on 04.09.2026.
//

import SwiftUI
import CoreData

@main
struct IOTA_WatchdogApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
