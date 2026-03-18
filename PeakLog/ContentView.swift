//
//  ContentView.swift
//  PeakLog
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showHistory = false
    @State private var showProfile = false

    var body: some View {
        ZStack {
            ChatScreen(
                onShowHistory: {
                    withAnimation(.easeInOut(duration: 0.3)) { showHistory = true }
                },
                onShowProfile: {
                    withAnimation(.easeInOut(duration: 0.3)) { showProfile = true }
                }
            )

            if showHistory {
                HistoryScreen(onBack: {
                    withAnimation(.easeInOut(duration: 0.3)) { showHistory = false }
                })
                .transition(.move(edge: .leading))
                .zIndex(1)
            }

            if showProfile {
                ProfileScreen(onBack: {
                    withAnimation(.easeInOut(duration: 0.3)) { showProfile = false }
                })
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }
        }
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
}
