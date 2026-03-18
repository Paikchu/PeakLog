//
//  PeakLogApp.swift
//  PeakLog
//
//  Created by max on 2026/3/18.
//

import SwiftUI

@main
struct PeakLogApp: App {
    @StateObject private var themeManager = ThemeManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
        }
    }
}
