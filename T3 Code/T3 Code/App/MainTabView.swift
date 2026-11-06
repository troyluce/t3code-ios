import SwiftUI

struct MainTabView: View {
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue
    @State private var selectedTab: Tab = .threads

    enum Tab: Hashable {
        case threads
        case settings
    }

    var body: some View {
        let tabs = TabView(selection: $selectedTab) {
            ThreadsListView()
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.threads)

            SettingsTabView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .tint(AppAccent.color(for: accentRaw))

        if #available(iOS 26.0, *) {
            tabs.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabs
        }
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    var body: some View {
        SettingsView(isModal: false)
    }
}
