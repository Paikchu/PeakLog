import Combine
import SwiftUI

@MainActor
final class ThemeManager: ObservableObject {

    @Published var isDarkMode: Bool {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: "peaklog.isDarkMode")
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: "peaklog.isDarkMode") == nil {
            self.isDarkMode = true
        } else {
            self.isDarkMode = UserDefaults.standard.bool(forKey: "peaklog.isDarkMode")
        }
    }

    var colorScheme: ColorScheme {
        isDarkMode ? .dark : .light
    }
}
