import SwiftUI
import CoreData

struct TrackerView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var selectedTab: Int = 0

    init() {
        // Pretty tab bar (iOS 15+)
        let ap = UITabBarAppearance()
        ap.configureWithTransparentBackground()
        ap.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        ap.stackedLayoutAppearance.selected.iconColor = .systemTeal
        ap.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.systemTeal]
        ap.stackedLayoutAppearance.normal.iconColor = .lightGray
        ap.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.lightGray]
        UITabBar.appearance().standardAppearance = ap
        UITabBar.appearance().scrollEdgeAppearance = ap
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Track
            MainView(context: context)
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text("Track")
                }
                .tag(0)

            // Progress (placeholder)
            LeaderboardView()
                .tabItem {
                    Image(systemName: "chart.bar.fill")
                    Text("Progress")
                }
                .tag(1)

            // Settings (placeholder)
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(2)

            // Quit Plan (placeholder)
            QuittingPlanView()
                .tabItem {
                    Image(systemName: "bolt.fill")
                    Text("Quit Plan")
                }
                .tag(3)
        }
        .tint(.teal)
    }
}

#Preview {
    TrackerView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
