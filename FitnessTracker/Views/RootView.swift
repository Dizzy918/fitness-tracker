import SwiftUI

struct RootView: View {
    /// Display units. Held here and pushed into the environment so every screen
    /// redraws the moment the preference changes — the alternative, each view
    /// reading defaults on its own, leaves half the app in the old units until
    /// it happens to be rebuilt.
    @AppStorage(UnitSystem.defaultsKey) private var unitSystem: UnitSystem = .metric

    /// Five tabs is the ceiling before iOS collapses the rest behind "More".
    /// Routes earns a tab because it's an active tool you reach for; Shoes is a
    /// set-and-glance tracker, so it lives behind the Dashboard (which already
    /// surfaces its wear alerts). Import and settings sit in the Workouts toolbar.
    var body: some View {
        tabs.environment(\.units, UnitFormatter(unitSystem))
    }

    private var tabs: some View {
        TabView {
            WorkoutListView()
                .tabItem { Label("Workouts", systemImage: "figure.run") }
            RecoveryView()
                .tabItem { Label("Recovery", systemImage: "heart.text.square") }
            RouteListView()
                .tabItem { Label("Routes", systemImage: "map") }
            StrengthListView()
                .tabItem { Label("Strength", systemImage: "dumbbell") }
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.line.uptrend.xyaxis") }
        }
    }
}
