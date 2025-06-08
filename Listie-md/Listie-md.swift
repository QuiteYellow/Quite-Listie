//
//  ListsForMealieApp.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import SwiftUI

@main
struct ShoppingListApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var networkMonitor = NetworkMonitor()
    @State private var showSettingsOnLaunch = false

    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .environmentObject(networkMonitor)
                .environmentObject(settings)
                
        }
    }
}
