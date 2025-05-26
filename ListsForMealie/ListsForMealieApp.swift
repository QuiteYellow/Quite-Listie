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
    @State private var showSettingsOnLaunch = false

    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .environmentObject(settings)
                .onAppear {
                    if settings.serverURLString.isEmpty || settings.apiToken.isEmpty {
                        showSettingsOnLaunch = true
                    }
                }
                .sheet(isPresented: $showSettingsOnLaunch) {
                    SettingsView()
                        .environmentObject(settings)
                }
        }
    }
}
