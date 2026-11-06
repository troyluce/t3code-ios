import SwiftUI

@main
struct T3_CodeApp: App {
    @State private var env = AppEnvironment()
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(env)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .tint(AppAccent.color(for: accentRaw))
        }
    }
}
