import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case blue, violet, green, orange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: "蓝色"
        case .violet: "紫色"
        case .green: "绿色"
        case .orange: "橙色"
        }
    }

    var color: Color {
        switch self {
        case .blue:
            Color(light: Color(red: 0.255, green: 0.333, blue: 0.780),
                  dark: Color(red: 0.310, green: 0.420, blue: 0.930))
        case .violet:
            Color(light: Color(red: 0.410, green: 0.310, blue: 0.820),
                  dark: Color(red: 0.560, green: 0.470, blue: 0.960))
        case .green:
            Color(light: Color(red: 0.050, green: 0.520, blue: 0.360),
                  dark: Color(red: 0.180, green: 0.760, blue: 0.520))
        case .orange:
            Color(light: Color(red: 0.800, green: 0.360, blue: 0.080),
                  dark: Color(red: 0.940, green: 0.520, blue: 0.180))
        }
    }

    static func color(for rawValue: String) -> Color {
        (AppAccent(rawValue: rawValue) ?? .blue).color
    }
}

enum TranscriptDensity: String, CaseIterable, Identifiable {
    case compact, comfortable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: "紧凑"
        case .comfortable: "舒适"
        }
    }
}

enum ComposerSize: String, CaseIterable, Identifiable {
    case compact, comfortable, expanded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: "紧凑"
        case .comfortable: "舒适"
        case .expanded: "加高"
        }
    }

    var maxLines: Int {
        switch self {
        case .compact: 3
        case .comfortable: 5
        case .expanded: 8
        }
    }
}

extension UIApplication {
    static func dismissKeyboard() {
        shared.sendAction(#selector(UIResponder.resignFirstResponder),
                          to: nil,
                          from: nil,
                          for: nil)
    }
}
